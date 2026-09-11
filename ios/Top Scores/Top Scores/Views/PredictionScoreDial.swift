import SwiftUI
import UIKit

/// A bounded drum: the optional blank notch is deliberately distinct from a zero-goal pick.
struct PredictionScoreDialValues {
    let allowsEmpty: Bool

    var lastIndex: Int { allowsEmpty ? 21 : 20 }

    func index(for score: Int?) -> Int {
        guard let score else { return 0 }
        return min(20, max(0, score)) + (allowsEmpty ? 1 : 0)
    }

    func score(at index: Int) -> Int? {
        let index = min(lastIndex, max(0, index))
        return allowsEmpty && index == 0 ? nil : index - (allowsEmpty ? 1 : 0)
    }

    func nearestIndex(offset: CGFloat, spacing: CGFloat) -> Int {
        min(lastIndex, max(0, Int((offset / spacing).rounded())))
    }
}

struct PredictionScoreDial: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var scale = 1
    @Binding var score: Int?
    let team: String
    var allowsEmpty = true
    var large = false

    private var width: CGFloat { (large ? 80 : 44) * min(scale, 1.5) }
    private var height: CGFloat { (large ? 104 : 68) * min(scale, 1.5) }

    var body: some View {
        PredictionScoreWheel(
            score: $score,
            team: team,
            allowsEmpty: allowsEmpty,
            isEnabled: isEnabled,
            reduceMotion: reduceMotion,
            fontSize: (large ? 36 : 23) * min(scale, 1.5)
        )
        .frame(width: width, height: height)
        .background {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.06, blue: 0.12), BeatAIStyle.blue.opacity(0.20), Color(red: 0.02, green: 0.06, blue: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(BeatAIStyle.blue.opacity(isEnabled ? 0.75 : 0.20), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct PredictionScoreWheel: UIViewRepresentable {
    @Binding var score: Int?
    let team: String
    let allowsEmpty: Bool
    let isEnabled: Bool
    let reduceMotion: Bool
    let fontSize: CGFloat

    func makeUIView(context: Context) -> PredictionScoreDrumView {
        PredictionScoreDrumView(allowsEmpty: allowsEmpty)
    }

    func updateUIView(_ view: PredictionScoreDrumView, context: Context) {
        view.onSelection = { score = $0 }
        view.configure(score: score, team: team, enabled: isEnabled, reduceMotion: reduceMotion, fontSize: fontSize)
    }
}

/// UIScrollView owns the gesture so rotating a drum does not drag the containing match list.
final class PredictionScoreDrumView: UIScrollView, UIScrollViewDelegate {
    var onSelection: ((Int?) -> Void)?
    private let values: PredictionScoreDialValues
    private let feedback = UISelectionFeedbackGenerator()
    private var digits: [UILabel] = []
    private var selectedIndex = 0
    private var turning = false
    private var enabled = true
    private var reducedMotion = false
    private var previousSize = CGSize.zero
    private var spacing: CGFloat { max(24, bounds.height * 0.36) }

    init(allowsEmpty: Bool) {
        values = PredictionScoreDialValues(allowsEmpty: allowsEmpty)
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        decelerationRate = .fast
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        isDirectionalLockEnabled = true
        isAccessibilityElement = true
        for index in 0...values.lastIndex {
            let label = UILabel()
            label.text = values.score(at: index).map(String.init) ?? "–"
            label.textAlignment = .center
            label.isAccessibilityElement = false
            addSubview(label)
            digits.append(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(score: Int?, team: String, enabled: Bool, reduceMotion: Bool, fontSize: CGFloat) {
        self.reducedMotion = reduceMotion
        accessibilityLabel = "Your prediction for \(team), goals"
        accessibilityHint = enabled
            ? (values.allowsEmpty ? "Adjust from zero to twenty. Decrease below zero to clear the score." : "Adjust from zero to twenty.")
            : "This prediction cannot be changed"
        accessibilityTraits = enabled ? [.adjustable] : [.staticText, .notEnabled]
        if self.enabled != enabled {
            self.enabled = enabled
            isScrollEnabled = enabled
            if !enabled {
                turning = false
                setContentOffset(CGPoint(x: 0, y: CGFloat(selectedIndex) * spacing), animated: false)
            }
        }
        let index = values.index(for: score)
        if index != selectedIndex {
            turning = false
            selectedIndex = index
            setContentOffset(CGPoint(x: 0, y: CGFloat(index) * spacing), animated: false)
        }
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        for label in digits { label.font = font }
        updateAccessibilityValue()
        updateDigitAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize else { return }
        previousSize = bounds.size
        for (index, label) in digits.enumerated() {
            label.layer.transform = CATransform3DIdentity
            label.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: spacing)
            label.center = CGPoint(x: bounds.midX, y: bounds.height / 2 + CGFloat(index) * spacing)
        }
        contentSize = CGSize(width: bounds.width, height: bounds.height + CGFloat(values.lastIndex) * spacing)
        setContentOffset(CGPoint(x: 0, y: CGFloat(selectedIndex) * spacing), animated: false)
        updateDigitAppearance()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        turning = enabled
        if turning { feedback.prepare() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if turning && enabled {
            select(values.nearestIndex(offset: contentOffset.y, spacing: spacing))
        }
        updateDigitAppearance()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let index = reducedMotion ? selectedIndex : values.nearestIndex(offset: targetContentOffset.pointee.y, spacing: spacing)
        targetContentOffset.pointee = CGPoint(x: 0, y: CGFloat(index) * spacing)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    private func settle() {
        turning = false
        setContentOffset(CGPoint(x: 0, y: CGFloat(selectedIndex) * spacing), animated: !reducedMotion)
    }

    private func select(_ index: Int) {
        guard enabled, index != selectedIndex else { return }
        selectedIndex = index
        feedback.selectionChanged()
        feedback.prepare()
        updateAccessibilityValue()
        onSelection?(values.score(at: index))
    }

    private func updateAccessibilityValue() {
        accessibilityValue = values.score(at: selectedIndex).map(String.init) ?? "Not entered"
    }

    private func updateDigitAppearance() {
        for (index, label) in digits.enumerated() {
            let distance = CGFloat(index) - contentOffset.y / spacing
            label.isHidden = reducedMotion ? index != selectedIndex : abs(distance) > 1.6
            guard !label.isHidden else { continue }
            label.textColor = index == selectedIndex ? .white : UIColor(BeatAIStyle.muted)
            if reducedMotion {
                label.alpha = 1
                label.layer.transform = CATransform3DMakeTranslation(0, -distance * spacing, 0)
            } else {
                label.alpha = max(0.12, 1 - abs(distance) * 0.55)
                var transform = CATransform3DIdentity
                transform.m34 = -1 / 240
                transform = CATransform3DRotate(transform, -min(1, max(-1, distance)) * .pi / 3, 1, 0, 0)
                label.layer.transform = transform
            }
        }
    }

    override func accessibilityIncrement() { adjust(by: 1) }
    override func accessibilityDecrement() { adjust(by: -1) }

    private func adjust(by change: Int) {
        guard enabled else { return }
        turning = false
        select(min(values.lastIndex, max(0, selectedIndex + change)))
        setContentOffset(CGPoint(x: 0, y: CGFloat(selectedIndex) * spacing), animated: !reducedMotion)
    }
}
