import XCTest
@testable import MeetingProviders

final class SummarySanitizerTests: XCTestCase {
    func testCollapsesLoopedQuote() {
        let loop = "much " + Array(repeating: "much", count: 40).joined(separator: " ")
        let cleaned = SummarySanitizer.clean("I think he is " + loop + " passionate.")
        XCTAssertFalse(cleaned.contains("much much much"))
        XCTAssertTrue(cleaned.contains("much"))
        XCTAssertTrue(cleaned.contains("passionate"))
    }

    func testStripsPartHeadings() {
        let text = """
        ## Part 1 of 2

        **TL;DR:** first

        ## Part 2 of 2

        **TL;DR:** second
        """
        let cleaned = SummarySanitizer.clean(text)
        XCTAssertFalse(cleaned.contains("Part 1 of 2"))
        XCTAssertFalse(cleaned.contains("Part 2 of 2"))
        XCTAssertTrue(SummarySanitizer.looksUnmerged(cleaned), "two TL;DRs still need a merge")
    }

    func testSingleTLDRIsMerged() {
        XCTAssertFalse(SummarySanitizer.looksUnmerged("**TL;DR:** one meeting"))
    }
}
