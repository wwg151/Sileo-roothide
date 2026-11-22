//
//  CSTextView.swift
//  Sileo
//
//  Created by CoolStar on 2/29/20.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import CoreText
import UIKit

// Leave the edit menu to UIKit so it can offer Translate for the selected text.
private final class DepictionSelectableTextView: UITextView, UITextViewDelegate {
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        contentInsetAdjustmentBehavior = .never
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        backgroundColor = .clear
        linkTextAttributes = [:]
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDepictionText(_ text: NSAttributedString) {
        measuredWidth = nil
        attributedText = text
    }

    func depictionTextHeight(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        if measuredWidth != width {
            measuredHeight = ceil(sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            measuredWidth = width
        }
        return measuredHeight
    }

    private func openLink(_ url: URL) {
        _ = (superview as? CSTextViewActionHandler)?.process(action: url.absoluteString)
    }

    func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction {
            openLink(url)
        }
        return false
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        return UIAction(title: defaultAction.title, image: defaultAction.image) { [weak self] _ in
            self?.openLink(url)
        }
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        if case .link = textItem.content { return nil }
        return UITextItem.MenuConfiguration(menu: defaultMenu)
    }
}

protocol CSTextViewActionHandler {
    func process(action: String) -> Bool
}

class CSTextView: UIView, CSTextViewActionHandler {
    public var attributedText: NSAttributedString? {
        didSet {
            if let selectableView = selectableView {
                selectableView.setDepictionText(attributedText ?? NSAttributedString(string: ""))
            } else {
                renderView.attributedText = attributedText
            }
        }
    }

    private let selectableView: DepictionSelectableTextView?
    private let renderView: CSTextRenderView
    private(set) public var overlayView: UIView

    init(frame: CGRect, allowsSelection: Bool) {
        renderView = CSTextRenderView(frame: CGRect(origin: .zero, size: frame.size))
        overlayView = UIView(frame: .zero)
        selectableView = allowsSelection ? DepictionSelectableTextView() : nil

        super.init(frame: frame)
        if let selectableView = selectableView {
            selectableView.frame = bounds
            selectableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(selectableView)
        } else {
            renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(renderView)
            overlayView.backgroundColor = UIColor(white: 0, alpha: 0.25)
            addSubview(overlayView)
        }
    }

    func depictionTextHeight(width: CGFloat) -> CGFloat {
        guard width > 0, let text = attributedText, text.length > 0 else { return 0 }
        if let selectableView = selectableView {
            return selectableView.depictionTextHeight(width: width)
        }
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
        didSet {
            renderView.backgroundColor = self.backgroundColor
        }
    }
    
    func process(action: String) -> Bool {
        let superview = self.superview as? CSTextViewActionHandler
        return superview?.process(action: action) ?? false
    }
}
