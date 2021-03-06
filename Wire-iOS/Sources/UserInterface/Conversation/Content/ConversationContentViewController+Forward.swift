//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import zmessaging
import Cartography

extension ZMConversation: ShareDestination {
}

// Should be called inside ZMUserSession.shared().performChanges block
func forEachNonEphemeral(in conversations: [ZMConversation], callback: (ZMConversation)->()) {
    conversations.forEach {
        let timeout = $0.destructionTimeout
        $0.updateMessageDestructionTimeout(timeout: .none)
        
        callback($0)
        
        $0.updateMessageDestructionTimeout(timeout: timeout)
    }
}

func forward(_ message: ZMMessage, to: [AnyObject]) {
    
    let conversations = to as! [ZMConversation]
    
    if Message.isTextMessage(message) {
        ZMUserSession.shared().performChanges {
            forEachNonEphemeral(in: conversations) { _ = $0.appendMessage(withText: message.textMessageData!.messageText) }
        }
    }
    else if Message.isImageMessage(message) {
        ZMUserSession.shared().performChanges {
            forEachNonEphemeral(in: conversations) { _ = $0.appendMessage(withImageData: message.imageMessageData!.imageData) }
        }
    }
    else if Message.isVideoMessage(message) || Message.isAudioMessage(message) || Message.isFileTransferMessage(message) {
        ZMUserSession.shared().performChanges {
            FileMetaDataGenerator.metadataForFileAtURL(message.fileMessageData!.fileURL, UTI: message.fileMessageData!.fileURL.UTI()) { fileMetadata in
                forEachNonEphemeral(in: conversations) { _ = $0.appendMessage(with: fileMetadata) }
            }
        }
    }
    else if Message.isLocationMessage(message) {
        let locationData = LocationData.locationData(withLatitude: message.locationMessageData!.latitude, longitude: message.locationMessageData!.longitude, name: message.locationMessageData!.name, zoomLevel: message.locationMessageData!.zoomLevel)
        ZMUserSession.shared().performChanges {
            forEachNonEphemeral(in: conversations) { _ = $0.appendMessage(with: locationData) }
        }
    }
    else {
        fatal("Cannot forward \(message)")
    }
}

extension ZMMessage: Shareable {
    
    public func share<ZMConversation>(to: [ZMConversation]) {
        forward(self, to: to as [AnyObject])
    }
    
    public typealias I = ZMConversation
    
    public func previewView() -> UIView {
        let cell: ConversationCell

        if Message.isTextMessage(self) {
            let textMessageCell = TextMessageCell(style: .default, reuseIdentifier: "")
            textMessageCell.smallLinkAttachments = true
            textMessageCell.contentLayoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            
            textMessageCell.messageTextView.backgroundColor = ColorScheme.default().color(withName: ColorSchemeColorBackground)
            textMessageCell.messageTextView.layer.cornerRadius = 4
            textMessageCell.messageTextView.layer.masksToBounds = true
            textMessageCell.messageTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
            textMessageCell.messageTextView.textContainer.lineBreakMode = .byTruncatingTail
            textMessageCell.messageTextView.textContainer.maximumNumberOfLines = 2
            cell = textMessageCell
        }
        else if Message.isImageMessage(self) {
            let imageMessageCell = ImageMessageCell(style: .default, reuseIdentifier: "")
            imageMessageCell.contentLayoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            imageMessageCell.autoStretchVertically = false
            imageMessageCell.defaultLayoutMargins = .zero
            cell = imageMessageCell
        }
        else if Message.isVideoMessage(self) {
            cell = VideoMessageCell(style: .default, reuseIdentifier: "")
            cell.contentLayoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        else if Message.isAudioMessage(self) {
            cell = AudioMessageCell(style: .default, reuseIdentifier: "")
            cell.contentLayoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        else if Message.isLocationMessage(self) {
            let locationCell = LocationMessageCell(style: .default, reuseIdentifier: "")
            locationCell.contentLayoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            locationCell.containerHeightConstraint.constant = 120
            cell = locationCell
        }
        else if Message.isFileTransferMessage(self) {
            cell = FileTransferCell(style: .default, reuseIdentifier: "")
            cell.contentLayoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        else {
            fatal("Cannot create preview for \(self)")
        }
        
        let layoutProperties = ConversationCellLayoutProperties()
        layoutProperties.showSender       = false
        layoutProperties.showUnreadMarker = false
        layoutProperties.showBurstTimestamp = false
        layoutProperties.topPadding       = 0
        layoutProperties.alwaysShowDeliveryState = false
        
        cell.configure(for: self, layoutProperties: layoutProperties)
        
        constrain(cell, cell.contentView) { cell, contentView in
            cell.width >= 320
            cell.height <= 200
            contentView.edges == cell.edges
        }

        cell.messageToolboxView.isHidden = true
        cell.likeButton.isHidden = true
        cell.isUserInteractionEnabled = false
        cell.setSelected(false, animated: false)
        
        return cell
    }
}

extension ZMConversationList {
    func shareableConversations(excluding: ZMConversation) -> [ZMConversation] {
        return self.map { $0 as! ZMConversation }.filter { (conversation: ZMConversation) -> (Bool) in
            return (conversation.conversationType == .oneOnOne || conversation.conversationType == .group) &&
                conversation.isSelfAnActiveMember &&
                conversation != excluding
        }
    }
}

extension ConversationContentViewController: UIAdaptivePresentationControllerDelegate {
    @objc public func showForwardFor(message: ZMConversationMessage, fromCell: ConversationCell) {
        self.view.window!.endEditing(true)
        
        let conversations = SessionObjectCache.shared().allConversations.shareableConversations(excluding: message.conversation!)
        
        let shareViewController: ShareViewController<ZMConversation, ZMMessage> = ShareViewController(shareable: message as! ZMMessage, destinations: conversations)
        
        let displayInPopover: Bool = self.traitCollection.horizontalSizeClass == .regular &&
                                     self.traitCollection.horizontalSizeClass == .regular
                
        if displayInPopover {
            shareViewController.showPreview = false
        }
        
        shareViewController.preferredContentSize = CGSize(width: 320, height: 568)
        shareViewController.modalPresentationStyle = .popover
        
        if let popoverPresentationController = shareViewController.popoverPresentationController {
            popoverPresentationController.sourceRect = fromCell.selectionRect
            popoverPresentationController.sourceView = fromCell.selectionView
            popoverPresentationController.backgroundColor = UIColor(white: 0, alpha: 0.5)
            popoverPresentationController.permittedArrowDirections = [.up, .down]
        }
        
        shareViewController.presentationController?.delegate = self
        
        shareViewController.onDismiss = { (shareController: ShareViewController<ZMConversation, ZMMessage>) -> () in
            shareController.presentingViewController?.dismiss(animated: true) {
                UIApplication.shared.wr_updateStatusBarForCurrentControllerAnimated(true)
            }
        }
        UIApplication.shared.keyWindow?.rootViewController?.present(shareViewController, animated: true) {
            UIApplication.shared.wr_updateStatusBarForCurrentControllerAnimated(true)
        }
    }
    
    public func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        let displayInPopover = self.traitCollection.horizontalSizeClass == .regular &&
                               self.traitCollection.horizontalSizeClass == .regular
        
        return displayInPopover ? .popover : .overFullScreen
    }
}
