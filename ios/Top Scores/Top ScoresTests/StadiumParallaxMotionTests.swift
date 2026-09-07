import CoreGraphics
import CoreMotion
import Testing
@testable import Top_Scores

struct StadiumParallaxMotionTests {
    @Test func filteringEasesTowardClampedTranslation() {
        var filter = StadiumParallaxFilter()

        let first = filter.update(horizontalAngle: 1, verticalAngle: -1, timestamp: 0)
        var settled = first
        for frame in 1 ... 240 {
            settled = filter.update(
                horizontalAngle: 1,
                verticalAngle: -1,
                timestamp: Double(frame) / 60
            )
        }

        #expect(abs(first.width) < StadiumParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(first.height) < StadiumParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) <= StadiumParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(settled.height) <= StadiumParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) > abs(first.width))
        #expect(abs(settled.height) > abs(first.height))
    }

    @Test func filteringSmoothlyReturnsToCentre() {
        var filter = StadiumParallaxFilter()
        for frame in 0 ... 120 {
            _ = filter.update(
                horizontalAngle: 0.18,
                verticalAngle: -0.18,
                timestamp: Double(frame) / 60
            )
        }
        let displaced = filter.translation
        var returned = displaced
        for frame in 121 ... 360 {
            returned = filter.update(
                horizontalAngle: 0,
                verticalAngle: 0,
                timestamp: Double(frame) / 60
            )
        }

        #expect(abs(returned.width) < abs(displaced.width))
        #expect(abs(returned.height) < abs(displaced.height))
        #expect(abs(returned.width) < 0.01)
        #expect(abs(returned.height) < 0.01)
    }

    @Test func filteringIgnoresTinyAttitudeNoise() {
        var filter = StadiumParallaxFilter()
        let translation = filter.update(
            horizontalAngle: 0.003,
            verticalAngle: -0.003,
            timestamp: 0
        )

        #expect(translation == .zero)
    }

    @Test func projectionProvidesIndependentPortraitAxes() {
        let angle = 0.12
        let horizontal = StadiumParallaxAttitudeProjection.screenAngles(
            quaternion: CMQuaternion(x: 0, y: sin(angle / 2), z: 0, w: cos(angle / 2)),
            orientation: .portrait
        )
        let vertical = StadiumParallaxAttitudeProjection.screenAngles(
            quaternion: CMQuaternion(x: sin(angle / 2), y: 0, z: 0, w: cos(angle / 2)),
            orientation: .portrait
        )

        #expect(abs(horizontal.horizontal - angle) < 0.0001)
        #expect(abs(horizontal.vertical) < 0.0001)
        #expect(abs(vertical.horizontal) < 0.0001)
        #expect(abs(vertical.vertical - angle) < 0.0001)
    }
}
