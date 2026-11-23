import XCTest

/// 上滑切下一集：滑完那一刻屏上应该是本集首帧（海报），不是黑屏 / 封面占位；连滑两集不用等下载
final class HGSwipeTiming: XCTestCase {
    func testSwipeShowsPosterAndPlays() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HG_START_TAB"] = "discover"
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS '集'")).element(boundBy: Int(ProcessInfo.processInfo.environment["HG_CARD"] ?? "2") ?? 2)
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        let ep = app.buttons["hg.episode.3"]
        XCTAssertTrue(ep.waitForExistence(timeout: 30))
        ep.tap()
        let surface = app.otherElements["hg.player.surface"]
        XCTAssertTrue(wait(surface, "playing-3", 60), "第 3 集没起播")
        sleep(5)   // 正常看几秒：后台预下第 4、5 集
        // 连滑两集，中间不停
        surface.swipeUp(velocity: .fast)
        shot(app, "swipe-4-immediate")
        XCTAssertTrue(wait(surface, "playing-4", 10), "第 4 集没起播")
        surface.swipeUp(velocity: .fast)
        shot(app, "swipe-5-immediate")
        XCTAssertTrue(wait(surface, "playing-5", 10), "连滑第 5 集要等（没预下）")
        sleep(1)
        shot(app, "ep5-playing")
    }

    private func wait(_ e: XCUIElement, _ v: String, _ t: TimeInterval) -> Bool {
        let x = expectation(for: NSPredicate(format: "value == %@", v), evaluatedWith: e)
        let start = Date()
        let ok = XCTWaiter().wait(for: [x], timeout: t) == .completed
        print("HGSW \(v) waited \(Int(Date().timeIntervalSince(start) * 1000))ms ok=\(ok)")
        return ok
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
