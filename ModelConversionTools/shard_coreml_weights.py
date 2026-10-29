"""Losslessly lay out Core ML blobs in bounded files; no graph or tensor-value changes."""
import gc
import hashlib
from pathlib import Path
import tempfile


def save_sharded_model(model, destination, shard_bytes=64*1024*1024):
    import coremltools as ct
    from coremltools.proto import MIL_pb2
    from coremltools.libmilstoragepython import _BlobStorageReader, _BlobStorageWriter
    spec = model.get_spec()
    kinds = {'FLOAT32':'float','FLOAT16':'fp16','INT32':'int32','INT16':'int16','INT8':'int8',
             'UINT32':'uint32','UINT16':'uint16','UINT8':'uint8','UINT1':'uint1','UINT2':'uint2',
             'UINT3':'uint3','UINT4':'uint4','UINT6':'uint6','INT4':'int4'}
    readers, replacements, checks, writers = {}, {}, [], []
    def values(block):
        for operation in block.operations:
            yield from operation.attributes.values()
            # constexpr inputs can contain blob literals directly rather than through const ops.
            for argument in operation.inputs.values():
                for binding in argument.arguments:
                    if binding.HasField('value'):
                        yield binding.value
            for nested in operation.blocks:
                yield from values(nested)
    with tempfile.TemporaryDirectory(prefix='hat-weight-layout-') as directory:
        root = Path(directory)
        writer, filename, estimated = None, None, 0
        for function in spec.mlProgram.functions.values():
            for block in function.block_specializations.values():
                for value in values(block):
                    if not value.HasField('blobFileValue'):
                        continue
                    blob = value.blobFileValue
                    key = (blob.fileName,blob.offset,value.type.tensorType.dataType)
                    if key not in replacements:
                        datatype = MIL_pb2.DataType.Name(value.type.tensorType.dataType)
                        if datatype not in kinds:
                            raise RuntimeError('Unsupported Core ML blob type: '+datatype)
                        kind = kinds[datatype]
                        source = Path(model.weights_dir) / Path(blob.fileName).name
                        reader = readers.setdefault(str(source),_BlobStorageReader(str(source)))
                        array = getattr(reader,'read_'+kind+'_data')(blob.offset)
                        required = array.nbytes + 256
                        if required > 96*1024*1024:
                            raise RuntimeError('One tensor exceeds the bounded blob limit')
                        if writer is None or estimated+required > shard_bytes:
                            filename = 'weight.bin' if not writers else f'weight_{len(writers):03d}.bin'
                            writer = _BlobStorageWriter(str(root/filename))
                            writers.append(writer)
                            estimated = 0
                        offset = getattr(writer,'write_'+kind+'_data')(array)
                        estimated += required
                        replacements[key] = (filename,offset)
                        checks.append((filename,offset,kind,hashlib.sha256(array.tobytes()).hexdigest()))
                    filename_for_value, offset = replacements[key]
                    blob.fileName = '@model_path/weights/'+filename_for_value
                    blob.offset = offset
        writer = None
        writers.clear()
        gc.collect() # flush/close the writer handles before independently reading every blob
        copied_readers = {}
        for filename,offset,kind,expected in checks:
            reader = copied_readers.setdefault(filename,_BlobStorageReader(str(root/filename)))
            restored = getattr(reader,'read_'+kind+'_data')(offset)
            if hashlib.sha256(restored.tobytes()).hexdigest() != expected:
                raise RuntimeError('Core ML blob layout changed tensor bytes')
        shards = [{'file':p.name,'bytes':p.stat().st_size} for p in sorted(root.iterdir())]
        if not shards or any(entry['bytes'] >= 96*1024*1024 for entry in shards):
            raise RuntimeError('Core ML weight file exceeds the bounded source-asset limit')
        saved = ct.models.MLModel(spec,weights_dir=str(root),skip_model_load=True)
        saved.save(str(destination))
    return {'tensorBlobsVerifiedByteIdentical':len(checks),'files':shards}
