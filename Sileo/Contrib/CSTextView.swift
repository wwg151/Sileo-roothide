//
//  CSTextView.swift
//  Sileo
//
//  Created by CoolStar on 2/29/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import CoreText
import UIKit

protocol CSTextViewActionHandler {
    func process(action: String) -> Bool
}

class CSTextView: UIView, CSTextViewActionHandler {
    public var attributedText: NSAttributedString? {
        didSet { renderView.attributedText = attributedText }
    }

    private let renderView: CSTextRenderView
    private let translatePage: (() -> Bool)?
    private(set) public var overlayView: UIView

    init(frame: CGRect, translatePage: (() -> Bool)? = nil) {
        renderView = CSTextRenderView(frame: CGRect(origin: .zero, size: frame.size))
        overlayView = UIView(frame: .zero)
        self.translatePage = translatePage

        super.init(frame: frame)
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(renderView)
        overlayView.backgroundColor = UIColor(white: 0, alpha: 0.25)
        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)

        if translatePage != nil {
            addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(translateLongPress(_:))))
            renderView.accessibilityCustomActions = [UIAccessibilityCustomAction(
                name: String(localizationKey: "Depiction_Translation_Menu"), target: self,
                selector: #selector(translateAccessibilityAction(_:)))
            ]
        }
    }

    @objc private func translateLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        _ = translateAccessibilityAction(nil)
    }

    @objc private func translateAccessibilityAction(_ action: UIAccessibilityCustomAction?) -> Bool {
        guard let text = attributedText, text.length > 0 else { return false }
        return translatePage?() ?? false
    }

    func depictionTextHeight(width: CGFloat) -> CGFloat {
        guard width > 0, let text = attributedText, text.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, targetSize, nil).height
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        renderView.setNeedsDisplay()
    }

    override var backgroundColor: UIColor? {
        didSet { renderView.backgroundColor = self.backgroundColor }
    }

    func process(action: String) -> Bool {
        let superview = self.superview as? CSTextViewActionHandler
        return superview?.process(action: action) ?? false
    }
}
