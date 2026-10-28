import Foundation
import TruongScalerCore

/// Descriptor for a single row-major tile (`docs/DEVELOPMENT.md` Section 1.1).
public struct TileDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let tileIndex: Int
    public let row: Int
    public let col: Int
    public let inputOriginX: Int
    public let inputOriginY: Int
    public let inputSize: Int              // Always 256 (Tier A) or 192 (Tier B)
    public let outputOriginX: Int
    public let outputOriginY: Int
    public let outputSize: Int             // inputSize * scaleFactor
    public let actualLeftOverlapOut: Int   // Dynamic output overlap with tile (row, col - 1)
    public let actualTopOverlapOut: Int    // Dynamic output overlap with tile (row - 1, col)

    public var id: Int { tileIndex }

    public init(
        tileIndex: Int,
        row: Int,
        col: Int,
        inputOriginX: Int,
        inputOriginY: Int,
        inputSize: Int,
        outputOriginX: Int,
        outputOriginY: Int,
        outputSize: Int,
        actualLeftOverlapOut: Int,
        actualTopOverlapOut: Int
    ) {
        self.tileIndex = tileIndex
        self.row = row
        self.col = col
        self.inputOriginX = inputOriginX
        self.inputOriginY = inputOriginY
        self.inputSize = inputSize
        self.outputOriginX = outputOriginX
        self.outputOriginY = outputOriginY
        self.outputSize = outputSize
        self.actualLeftOverlapOut = actualLeftOverlapOut
        self.actualTopOverlapOut = actualTopOverlapOut
    }
}

/// Complete row-major tile grid plan (`docs/DEVELOPMENT.md` Section 1.1).
public struct TileGridPlan: Codable, Sendable, Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let scaleFactor: ScaleFactor
    public let tileConfig: TileConfiguration
    public let rows: Int
    public let cols: Int
    public let tiles: [TileDescriptor]

    public var totalTiles: Int { tiles.count }

    public init(
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        scaleFactor: ScaleFactor,
        tileConfig: TileConfiguration,
        rows: Int,
        cols: Int,
        tiles: [TileDescriptor]
    ) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.scaleFactor = scaleFactor
        self.tileConfig = tileConfig
        self.rows = rows
        self.cols = cols
        self.tiles = tiles
    }
}

/// Partitions any source canvas into fixed-size `T x T` input tiles in row-major order.
/// Specification: `docs/DEVELOPMENT.md` Section 1.2.
public struct TileGridPlanner: Sendable {
    public static func computeAxisOrigins(length: Int, tileSize: Int, stride: Int) -> [Int] {
        guard length > tileSize else { return [0] }
        let safeStride = max(1, stride)
        var origins: [Int] = []
        var pos = 0
        while true {
            if pos + tileSize >= length {
                let clampedOrigin = length - tileSize
                if origins.last != clampedOrigin {
                    origins.append(clampedOrigin)
                }
                break
            }
            origins.append(pos)
            pos += safeStride
        }
        return origins
    }

    public static func makePlan(
        sourceWidth: Int,
        sourceHeight: Int,
        scaleFactor: ScaleFactor,
        tileConfig: TileConfiguration
    ) -> TileGridPlan {
        let T = tileConfig.inputTileSize
        let D = tileConfig.effectiveInputStride
        let S = scaleFactor.rawValue

        let xOrigins = computeAxisOrigins(length: sourceWidth, tileSize: T, stride: D)
        let yOrigins = computeAxisOrigins(length: sourceHeight, tileSize: T, stride: D)

        var descriptors: [TileDescriptor] = []
        descriptors.reserveCapacity(xOrigins.count * yOrigins.count)

        var idx = 0
        for (row, currY) in yOrigins.enumerated() {
            let topOverlapOut: Int
            if row == 0 {
                topOverlapOut = 0
            } else {
                let prevY = yOrigins[row - 1]
                let topOverlapIn = max(0, (prevY + T) - currY)
                topOverlapOut = topOverlapIn * S
            }

            for (col, currX) in xOrigins.enumerated() {
                let leftOverlapOut: Int
                if col == 0 {
                    leftOverlapOut = 0
                } else {
                    let prevX = xOrigins[col - 1]
                    let leftOverlapIn = max(0, (prevX + T) - currX)
                    leftOverlapOut = leftOverlapIn * S
                }

                descriptors.append(
                    TileDescriptor(
                        tileIndex: idx,
                        row: row,
                        col: col,
                        inputOriginX: currX,
                        inputOriginY: currY,
                        inputSize: T,
                        outputOriginX: currX * S,
                        outputOriginY: currY * S,
                        outputSize: T * S,
                        actualLeftOverlapOut: leftOverlapOut,
                        actualTopOverlapOut: topOverlapOut
                    )
                )
                idx += 1
            }
        }

        return TileGridPlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: sourceWidth * S,
            outputHeight: sourceHeight * S,
            scaleFactor: scaleFactor,
            tileConfig: tileConfig,
            rows: yOrigins.count,
            cols: xOrigins.count,
            tiles: descriptors
        )
    }
}
