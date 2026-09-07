import Foundation

struct ScreenshotPinnedZoom {
    let originalSize: CGSize
    let scales: [CGFloat]
    private(set) var scale: CGFloat = 1
    private var scrollRemainder: CGFloat = 0

    init(originalSize: CGSize) {
        self.originalSize = originalSize
        let minimum = min(1, 80 / max(originalSize.width, originalSize.height))
        var values: [CGFloat] = [minimum, 1, 2.5]
        let firstStep = Int(floor(log(Double(minimum)) / log(1.05)))
        let lastStep = Int(ceil(log(2.5) / log(1.05)))
        for step in firstStep...lastStep {
            let value = CGFloat(pow(1.05, Double(step)))
            if value > minimum, value < 2.5 { values.append(value) }
        }
        scales = Array(Set(values)).sorted()
    }

    var imageSize: CGSize { CGSize(width: originalSize.width * scale, height: originalSize.height * scale) }
    var windowSize: CGSize { CGSize(width: max(44, imageSize.width), height: max(44, imageSize.height)) }

    mutating func reset() { scale = 1; scrollRemainder = 0 }
    mutating func resetScroll() { scrollRemainder = 0 }

    mutating func scroll(delta: CGFloat, precise: Bool) -> Bool {
        guard delta.isFinite, delta != 0 else { return false }
        let steps: Int
        if precise {
            scrollRemainder += delta
            steps = Int(min(4, max(-4, scrollRemainder / 12)))
            guard steps != 0 else { return false }
            scrollRemainder -= CGFloat(steps) * 12
        } else { steps = delta > 0 ? 1 : -1 }
        let index = scales.firstIndex(of: scale) ?? scales.firstIndex(of: 1)!
        let next = scales[min(scales.count - 1, max(0, index + steps))]
        if next == scales.first || next == scales.last { scrollRemainder = 0 }
        guard next != scale else { return false }
        scale = next
        return true
    }

    func frame(anchoredAt point: CGPoint, in previous: CGRect) -> CGRect {
        let x = min(1, max(0, (point.x - previous.minX) / previous.width))
        let y = min(1, max(0, (point.y - previous.minY) / previous.height))
        return CGRect(x: point.x - windowSize.width * x, y: point.y - windowSize.height * y,
                      width: windowSize.width, height: windowSize.height)
    }
}
