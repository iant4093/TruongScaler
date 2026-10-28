#if canImport(UIKit)
import UIKit

/// A viewport overlay bounded by the actual visible photo. Only its handle receives touches;
/// pan/pinch/chrome gestures elsewhere continue to reach the image scroll view.
@MainActor
final class SplitComparisonOverlayView: UIControl {
    let divider = UIView()
    let handle = UIImageView()
    private(set) var fraction: CGFloat = 0.5
    var onFractionChanged: ((CGFloat) -> Void)?
    lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        gesture.maximumNumberOfTouches = 1
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.65)
        handle.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        handle.layer.cornerRadius = 15
        handle.layer.borderWidth = 1
        handle.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        handle.image = UIImage(systemName: "arrow.left.and.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        handle.tintColor = .white
        handle.contentMode = .center
        addSubview(divider)
        addSubview(handle)
        addGestureRecognizer(panGesture)
        isAccessibilityElement = true
        accessibilityLabel = "Before and after comparison"
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "photo-comparison-slider"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(fraction: CGFloat) {
        self.fraction = fraction
        accessibilityValue = "\(Int((fraction * 100).rounded())) percent original"
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = bounds.width * fraction
        divider.frame = CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)
        handle.frame = CGRect(x: x - 15, y: bounds.midY - 15, width: 30, height: 30)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) && handle.frame.insetBy(dx: -10, dy: -10).contains(point)
    }

    func changeFraction(to value: CGFloat) {
        guard value.isFinite else { return }
        let value = min(max(value, 0.05), 0.95)
        configure(fraction: value)
        onFractionChanged?(value)
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard bounds.width > 0 else { return }
        changeFraction(to: gesture.location(in: self).x / bounds.width)
    }

    override func accessibilityIncrement() { changeFraction(to: fraction + 0.1) }
    override func accessibilityDecrement() { changeFraction(to: fraction - 0.1) }
}
#endif
