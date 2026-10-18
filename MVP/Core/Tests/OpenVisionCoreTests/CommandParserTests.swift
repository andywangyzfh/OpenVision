import XCTest
@testable import OpenVisionCore

final class CommandParserTests: XCTestCase {
    let parser = CommandParser()

    func testChineseAndEnglishStopIntentsMustBeEntireUtterance() {
        for text in ["停", "停止！", " 请停止。\n", "别说了", "STOP!", "  Please   stop. ", "stop speaking"] {
            XCTAssertEqual(parser.parse(text), .stop, text)
        }
        for text in ["我不想停止学习", "请解释停止标志", "stopwatch", "unstoppable", "how do stop signs work?", "please stop by the bakery", "do not stop", "don't stop", "stop, then explain"] {
            guard case .conversation = parser.parse(text) else { return XCTFail("False stop: \(text)") }
        }
    }

    func testCancelIntentsAndFalsePositives() {
        for text in ["取消", "算了。", "不用了", "CANCEL!", "never mind"] {
            XCTAssertEqual(parser.parse(text), .cancel, text)
        }
        for text in ["取消订单的方法是什么", "explain cancellation policy", "don't cancel", "never mind the weather, tell me a joke"] {
            guard case .conversation = parser.parse(text) else { return XCTFail("False cancel: \(text)") }
        }
    }

    func testChineseOnDemandPhotoCommandsAndQuestionExtraction() {
        let cases: [(String, String)] = [
            ("看看这个", ""),
            ("帮我看看这个。", ""),
            ("看看这个，帮我翻译成中文。", "帮我翻译成中文"),
            ("看一下这个是什么？", "是什么"),
            ("看看这个怎么用？", "怎么用"),
            ("看看这个，是 A 还是 B？", "是 A 还是 B"),
            ("拍照问答：标签写的是什么？", "标签写的是什么"),
            ("拍照看看", ""),
            ("拍张照片，然后描述画面。", "然后描述画面"),
            ("拍照解释这个按钮", "解释这个按钮")
        ]
        for (text, question) in cases {
            XCTAssertEqual(parser.parse(text), .photo(question: question), text)
        }
    }

    func testEnglishPhotoCommandsWithWordBoundaries() {
        let cases: [(String, String)] = [
            ("Look at this!", ""),
            ("look at this photo, what does the label say?", "what does the label say"),
            ("Take a photo and explain the controls.", "explain the controls"),
            ("please take a picture: read this menu", "read this menu"),
            ("What am I looking at?", ""),
            ("What do you see?", ""),
            ("Look at this—android settings", "android settings")
        ]
        for (text, question) in cases {
            XCTAssertEqual(parser.parse(text), .photo(question: question), text)
        }
    }

    func testCameraNeverTriggersForIncidentalCameraWords() {
        for text in ["我昨天拍照了", "怎么拍照", "拍照功能怎么用", "拍照技术有什么技巧", "看看这个词是什么意思", "look at thistle", "take a photography class", "please explain how to take a photo", "what is this?", "这是什么？", "don't take a photo", "what do you seek in a camera?"] {
            guard case .conversation = parser.parse(text) else { return XCTFail("Unexpected photo: \(text)") }
        }
    }

    func testShortMandarinIsNotDroppedByEnglishLengthHeuristics() {
        for text in ["好", "对", "继续", "你好", "为什么", "讲讲", "是", "不", "2"] {
            XCTAssertEqual(parser.parse(text), .conversation(text: text))
        }
        for text in ["", " \n ", "。！？", "..."] { XCTAssertEqual(parser.parse(text), .empty) }
    }
}
