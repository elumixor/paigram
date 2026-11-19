import Foundation
import CoreGraphics

/// Geometry of the "Copy" button drawn at the trailing edge of a code block's header row.
public enum CodeBlockCopyButtonLayout {
    public static let edgeInset: CGFloat = 4.0
    public static let iconSize = CGSize(width: 14.0, height: 14.0)
    public static let iconLabelSpacing: CGFloat = 3.0
    /// Gap kept between the language title and the button.
    public static let titleSpacing: CGFloat = 8.0
    public static let minimumHitSize: CGFloat = 44.0

    /// Size of the button image: icon followed by the label, vertically centered.
    public static func buttonSize(labelSize: CGSize) -> CGSize {
        let width = ceil(iconSize.width + iconLabelSpacing + labelSize.width)
        let height = ceil(max(iconSize.height, labelSize.height))
        return CGSize(width: width, height: height)
    }

    /// Width the header row must reserve after the title so the button never overlaps it.
    public static func reservedHeaderWidth(buttonSize: CGSize) -> CGFloat {
        return buttonSize.width + titleSpacing
    }

    /// Button frame inside the block background: top-trailing corner.
    public static func buttonFrame(blockFrame: CGRect, buttonSize: CGSize) -> CGRect {
        return CGRect(
            origin: CGPoint(x: blockFrame.maxX - edgeInset - buttonSize.width, y: blockFrame.minY + edgeInset),
            size: buttonSize
        )
    }

    /// Tappable area: the button frame grown to at least 44pt each way, clipped to the block.
    public static func hitRect(blockFrame: CGRect, buttonSize: CGSize) -> CGRect {
        let frame = buttonFrame(blockFrame: blockFrame, buttonSize: buttonSize)
        let dx = max(0.0, (minimumHitSize - frame.width) / 2.0)
        let dy = max(0.0, (minimumHitSize - frame.height) / 2.0)
        let expanded = frame.insetBy(dx: -dx, dy: -dy)
        return expanded.intersection(blockFrame)
    }
}
