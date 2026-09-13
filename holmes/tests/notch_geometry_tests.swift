// Run: holmes/tests/run-work-activity-tests.sh
import AppKit

@main
struct NotchGeometryTests {
    @MainActor
    static func main() {
        let laptop = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 910),
            safeAreaTop: 32, leftAreaWidth: 660, rightAreaWidth: 660)
        check(laptop.contentTopInset > 32, "Content must start below a 32-point camera housing")
        check(laptop.closedSize == CGSize(width: 196, height: 32), "Closed island must cover the measured cutout")
        check(laptop.windowFrame.midX == 756, "Laptop island must align with the physical notch")
        verifyContained(laptop)

        let tallerCutout = NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1121),
            safeAreaTop: 48, leftAreaWidth: 790, rightAreaWidth: 810)
        check(tallerCutout.contentTopInset == laptop.contentTopInset + 16, "Safe-area growth must move ALL content downward")
        check(tallerCutout.openSize.height == laptop.openSize.height + 16, "Safe-area growth must grow the panel, not clip content")
        check(tallerCutout.anchorX == 890, "Asymmetric auxiliary areas must define the actual cutout center")
        verifyContained(tallerCutout)

        let external = NotchGeometry.layout(
            screenFrame: CGRect(x: -1920, y: 140, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 140, width: 1920, height: 1056), safeAreaTop: 0)
        check(external.hardwareHeight == 0 && external.contentTopInset == 12, "External displays must not reserve a fictional cutout")
        check(external.windowFrame.midX == -960 && external.windowFrame.maxY == 1220, "Host must use global screen coordinates")
        verifyContained(external)

        let narrow = NotchGeometry.layout(
            screenFrame: CGRect(x: 1920, y: -900, width: 600, height: 900),
            visibleFrame: CGRect(x: 1920, y: -900, width: 600, height: 876), safeAreaTop: 0)
        check(narrow.openSize.width == 560, "Narrow displays must reduce content width while retaining shadow room")
        verifyContained(narrow)
        let viewModel = NotchViewModel(geometry: tallerCutout)
        viewModel.open()
        check(viewModel.notchSize == tallerCutout.openSize, "Open must use the host display geometry")
        viewModel.close()
        check(viewModel.notchSize == tallerCutout.closedSize, "Closing must not switch back to NSScreen.main geometry")
        viewModel.taskActive = true
        check(viewModel.notchSize == tallerCutout.compactSize, "Running task must retain the below-cutout content area")
        print("Notch geometry: 4 display scenarios and state transitions passed")
    }

    static func verifyContained(_ layout: NotchGeometry.Layout) {
        check(layout.screenFrame.contains(layout.windowFrame), "Host window must stay inside its display")
        check(layout.windowSize.width >= layout.openSize.width + 40, "Expanded island needs horizontal shadow space")
        check(layout.windowSize.height >= layout.openSize.height + 20, "Expanded island needs bottom shadow space")
        check(layout.compactSize.width <= layout.openSize.width, "Compact status must fit the same host")
        check(layout.compactSize.height >= layout.contentTopInset + 64, "Compact status must fit below the camera")
        check(layout.openSize.height >= layout.contentTopInset + 200, "Expanded content must retain its usable height")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
