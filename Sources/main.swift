import Cocoa
import ImageIO
import UniformTypeIdentifiers

class Drop: NSView {
 var onFiles: (([URL]) -> Void)?
 var image: NSImage? { didSet { needsDisplay = true } }

 override init(frame: NSRect) {
  super.init(frame: frame)
  registerForDraggedTypes([.fileURL])
  wantsLayer = true
  layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
 }

 required init?(coder: NSCoder) { fatalError() }

 override func draw(_ dirtyRect: NSRect) {
  super.draw(dirtyRect)
  if let image, image.size.width > 0, image.size.height > 0 {
   let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
   let width = image.size.width * scale
   let height = image.size.height * scale
   image.draw(in: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                         width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
  } else {
   let message = "将一张或多张图片拖到这里" as NSString
   let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor]
   let size = message.size(withAttributes: style)
   message.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: style)
  }
 }

 static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
  (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
   .compactMap { ($0 as? NSURL).map { $0 as URL } }
 }

 override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
  Drop.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
 }

 override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
  let urls = Drop.fileURLs(from: sender.draggingPasteboard)
  guard !urls.isEmpty, let onFiles else { return false }
  onFiles(urls)
  return true
 }
}
private func trackSelectionBox(in view:NSView, event:NSEvent, changed:(CGRect) -> Void) {
 guard let window = view.window else { return }
 view.wantsLayer = true
 let box = CAShapeLayer()
 box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
 box.strokeColor = NSColor.secondaryLabelColor.cgColor
 box.lineWidth = 1
 box.zPosition = 100
 view.layer?.addSublayer(box)
 defer { box.removeFromSuperlayer() }
 let start = view.convert(event.locationInWindow,from:nil)
 changed(CGRect(origin:start,size:.zero))
 while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
  if next.type == .leftMouseUp { break }
  view.autoscroll(with:next)
  let end = view.convert(next.locationInWindow,from:nil)
  let rect = CGRect(x:min(start.x,end.x),y:min(start.y,end.y),
                    width:abs(start.x-end.x),height:abs(start.y-end.y))
  CATransaction.begin()
  CATransaction.setDisableActions(true)
  box.path = CGPath(rect:rect,transform:nil)
  CATransaction.commit()
  changed(rect)
 }
}

func movingFiles(_ files:[URL], selected:IndexSet, to slot:Int) -> [URL]? {
 guard !selected.isEmpty, selected.allSatisfy({ files.indices.contains($0) }),
       (0...files.count).contains(slot) else { return nil }
 let group = selected.map { files[$0] }
 var remaining = files.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
 let destination = slot - selected.filter { $0 < slot }.count
 remaining.insert(contentsOf:group,at:destination)
 return remaining
}

final class CompressionFileTable: NSTableView {
 static let rowType = NSPasteboard.PasteboardType("local.leo.imagecompress.file-rows")
 override func mouseDown(with event:NSEvent) {
  let point = convert(event.locationInWindow,from:nil)
  guard row(at:point) < 0 || point.x >= bounds.maxX-32 else { super.mouseDown(with:event); return }
  window?.makeFirstResponder(self)
  let additive = !event.modifierFlags.intersection([.command,.shift]).isEmpty
  let base = additive ? selectedRowIndexes : IndexSet()
  trackSelectionBox(in:self,event:event) { rect in
   let hits = IndexSet((0..<self.numberOfRows).filter { self.rect(ofRow:$0).intersects(rect) && rect.width > 0 && rect.height > 0 })
   self.selectRowIndexes(base.union(hits),byExtendingSelection:false)
  }
 }
 var removeSelection: (() -> Void)?
 override func keyDown(with event:NSEvent) {
  if event.keyCode == 51 || event.keyCode == 117 {
   removeSelection?()
  } else {
   super.keyDown(with:event)
  }
 }
}

final class App: NSObject, NSApplicationDelegate, NSTabViewDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
 var window: NSWindow!; var isCollageActive = false; var files: [URL] = []; var destination: URL?; let list = CompressionFileTable(); let pathLabel = NSTextField(labelWithString:"默认：每张原图旁的「压缩结果」文件夹"); let width = NSTextField(string:""), height = NSTextField(string:""), size = NSTextField(string:""); let status = NSTextField(labelWithString:"原图会保留；结果保存在原图旁的「压缩结果」文件夹。")
 private let compressionPreview = Drop(frame:NSRect(x:20,y:455,width:680,height:160))
 private let previewCaption = NSTextField(labelWithString:"选择图片查看预览；从列表右侧或底部空白处拖动框选")
 private let removeFilesButton = NSButton(title:"移除所选",target:nil,action:nil)
 private var compressionThumbnails: [URL:NSImage] = [:]

 func applicationDidFinishLaunching(_ notification: Notification) {
  window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:724),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false); window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
   .map { "拼图与压缩 · v\($0)" } ?? "拼图与压缩"
  window.delegate = self
  window.isReleasedWhenClosed = false
  installAppMenu()
  window.contentMinSize = NSSize(width:760,height:724)
  window.collectionBehavior.insert(.fullScreenPrimary)
  let pin = NSButton(title:"置顶",target:self,action:#selector(togglePinned(_:)))
  pin.setButtonType(.pushOnPushOff)
  pin.bezelStyle = .texturedRounded
  pin.frame = NSRect(x:0,y:0,width:65,height:24)
  pin.toolTip = "让窗口保持在其他普通窗口上方"
  let accessory = NSTitlebarAccessoryViewController()
  accessory.view = pin
  accessory.layoutAttribute = .right
  window.addTitlebarAccessoryViewController(accessory)
  window.center()
  let tabs = NSTabView(frame:NSRect(x:10,y:34,width:740,height:680)); tabs.autoresizingMask = [.width,.height]; tabs.delegate = self; window.contentView!.addSubview(tabs)
  let signature = NSTextField(labelWithString:"by 梁粤Leo")
  signature.frame = NSRect(x:580,y:8,width:160,height:18)
  signature.autoresizingMask = [.minXMargin]
  signature.alignment = .right
  signature.font = .systemFont(ofSize:12,weight:.medium)
  signature.textColor = .secondaryLabelColor
  window.contentView!.addSubview(signature)
  let compression = NSTabViewItem(identifier:"compression"); compression.label = "图片压缩"; let v = NSView(frame:NSRect(x:0,y:0,width:720,height:640)); v.autoresizingMask = [.width,.height]; compression.view = v; tabs.addTabViewItem(compression)
  let c = Collage(files:[], destination:nil); collage = c; c.chooseFiles = { [weak self] in self?.selectFiles() }; c.clearFiles = { [weak self] in self?.clearFiles() }; c.receiveFiles = { [weak self] in self?.addFiles($0) }
  c.editFiles = { [weak self] in self?.setFiles($0) }
  let collageTab = NSTabViewItem(identifier:"collage"); collageTab.label = "拼图"; collageTab.view = c.makeView(); tabs.addTabViewItem(collageTab); tabs.selectTabViewItem(compression)
  compressionPreview.autoresizingMask = [.width,.minYMargin]
  compressionPreview.onFiles = { [weak self] in self?.addFiles($0) }
  v.addSubview(compressionPreview)
  previewCaption.frame = NSRect(x:20,y:429,width:680,height:21)
  previewCaption.autoresizingMask = [.width,.minYMargin]
  previewCaption.lineBreakMode = .byTruncatingMiddle
  previewCaption.font = .systemFont(ofSize:12)
  previewCaption.textColor = .secondaryLabelColor
  v.addSubview(previewCaption)

  let scroll = ImageDropScrollView(frame:NSRect(x:20,y:275,width:680,height:145))
  scroll.autoresizingMask = [.width,.height]
  scroll.hasVerticalScroller = true
  scroll.borderType = .bezelBorder
  scroll.onFiles = { [weak self] in self?.addFiles($0) }
  let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("filename"))
  column.width = 660
  column.minWidth = 200
  list.addTableColumn(column)
  list.headerView = nil
  list.rowHeight = 46
  list.allowsMultipleSelection = true
  list.allowsEmptySelection = true
  list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
  list.dataSource = self
  list.delegate = self
  list.registerForDraggedTypes([.fileURL,CompressionFileTable.rowType])
  list.setDraggingSourceOperationMask(.move,forLocal:true)
  list.setDraggingSourceOperationMask(.copy,forLocal:false)
  list.removeSelection = { [weak self] in self?.removeSelectedFiles() }
  scroll.documentView = list
  v.addSubview(scroll)
  func button(_ title:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ action:Selector) { let b = NSButton(title:title,target:self,action:action); b.frame = NSRect(x:x,y:y,width:width,height:30); v.addSubview(b) }
  button("选择图片",20,238,100,#selector(selectFiles))
  removeFilesButton.frame = NSRect(x:130,y:238,width:100,height:30)
  removeFilesButton.target = self
  removeFilesButton.action = #selector(removeSelectedFiles)
  removeFilesButton.isEnabled = false
  v.addSubview(removeFilesButton)
  button("清空列表",240,238,100,#selector(clearFiles))
  func label(_ text:String,_ x:CGFloat,_ y:CGFloat) { let l = NSTextField(labelWithString:text); l.frame = NSRect(x:x,y:y,width:175,height:22); v.addSubview(l) }
  label("最大宽度（像素）",20,205); label("最大高度（像素）",220,205); label("文件上限（KB）",420,205)
  for (f,x) in [(width,20.0),(height,220.0),(size,420.0)] { f.frame = NSRect(x:x,y:177,width:170,height:25); f.placeholderString = "不限制"; v.addSubview(f) }
  button("选择保存位置",20,132,130,#selector(selectDestination)); pathLabel.frame = NSRect(x:160,y:137,width:440,height:20); pathLabel.lineBreakMode = .byTruncatingMiddle; v.addSubview(pathLabel)
  button("开始压缩",20,85,120,#selector(start)); status.frame = NSRect(x:20,y:20,width:580,height:55); status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping; v.addSubview(status)
  status.stringValue = "先添加图片并填写限制，再点击开始压缩。"
  window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
 }
 private func installAppMenu() {
  let menu = NSMenu()
  let item = NSMenuItem()
  let applicationMenu = NSMenu(title:"拼图与压缩")
  let show = NSMenuItem(title:"显示主窗口",action:#selector(showWindow),keyEquivalent:"")
  show.target = self
  applicationMenu.addItem(show)
  applicationMenu.addItem(.separator())
  let quit = NSMenuItem(title:"退出拼图与压缩",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
  quit.target = NSApp
  applicationMenu.addItem(quit)
  menu.addItem(item)
  item.submenu = applicationMenu
  NSApp.mainMenu = menu
 }

 @objc private func showWindow() {
  window.deminiaturize(nil)
  window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps:true)
 }

 func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows flag:Bool) -> Bool {
  showWindow()
  return true
 }

 func windowShouldClose(_ sender:NSWindow) -> Bool {
  let alert = NSAlert()
  alert.messageText = "关闭窗口还是退出程序？"
  alert.informativeText = "关闭窗口后，点击程序坞图标可继续编辑。退出程序会清空本次图片列表和编辑状态。"
  alert.addButton(withTitle:"关闭窗口")
  alert.addButton(withTitle:"退出程序")
  let cancel = alert.addButton(withTitle:"取消")
  cancel.keyEquivalent = "\u{1b}"
  handleCloseChoice(alert.runModal())
  return false
 }

 func handleCloseChoice(_ choice:NSApplication.ModalResponse) {
  switch choice {
  case .alertFirstButtonReturn: window.orderOut(nil)
  case .alertSecondButtonReturn: NSApp.terminate(nil)
  default: break
  }
 }

 @objc private func togglePinned(_ sender:NSButton) {
  let pinned = sender.state == .on
  window.level = pinned ? .floating : .normal
  sender.title = pinned ? "已置顶" : "置顶"
 }
 var collage: Collage?
 func tabView(_ tabView:NSTabView, didSelect tabViewItem:NSTabViewItem?) { isCollageActive = (tabViewItem?.identifier as? String) == "collage"; if isCollageActive { collage?.files = files; collage?.destination = destination; collage?.refresh() } }
 @objc func selectFiles() { let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.allowedContentTypes = [.image]; if p.runModal() == .OK { addFiles(p.urls) } }
 func addFiles(_ urls: [URL]) {
  var updated = files
  var seen = Set(files)
  for url in urls where seen.insert(url).inserted { updated.append(url) }
  setFiles(updated)
 }

 @objc func clearFiles() { setFiles([]) }

 private func setFiles(_ updated: [URL]) {
  let oldRow = list.selectedRow
  let selectedURLs = list.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil }
  files = updated
  let retained = Set(files)
  compressionThumbnails = compressionThumbnails.filter { retained.contains($0.key) }
  list.reloadData()
  if list.dataSource != nil {
   let rows = IndexSet(files.indices.filter { selectedURLs.contains(files[$0]) })
   if !rows.isEmpty {
    list.selectRowIndexes(rows,byExtendingSelection:false)
   } else if !files.isEmpty {
    list.selectRowIndexes(IndexSet(integer:min(max(0,oldRow),files.count-1)),byExtendingSelection:false)
   } else {
    list.deselectAll(nil)
   }
  }
  updateCompressionPreview()
  status.stringValue = files.isEmpty ? "列表已清空。" : "共 \(files.count) 张图片；设置限制后点击开始压缩。"
  collage?.files = files
  if isCollageActive { collage?.refresh() }
 }

 func numberOfRows(in tableView:NSTableView) -> Int { files.count }

 func tableView(_ tableView:NSTableView, viewFor tableColumn:NSTableColumn?, row:Int) -> NSView? {
  guard files.indices.contains(row) else { return nil }
  let url = files[row]
  let identifier = NSUserInterfaceItemIdentifier("compression-file")
  let cell = tableView.makeView(withIdentifier:identifier,owner:self) as? NSTableCellView ?? makeFileCell(identifier)
  cell.textField?.stringValue = url.lastPathComponent
  cell.toolTip = url.path
  if compressionThumbnails[url] == nil,
     let source = CGImageSourceCreateWithURL(url as CFURL,nil), let icon = thumbnail(source,edge:120) {
   compressionThumbnails[url] = NSImage(cgImage:icon,size:.zero)
  }
  cell.imageView?.image = compressionThumbnails[url]
  return cell
 }

 private func makeFileCell(_ identifier:NSUserInterfaceItemIdentifier) -> NSTableCellView {
  let cell = NSTableCellView(frame:NSRect(x:0,y:0,width:660,height:46))
  cell.identifier = identifier
  let icon = NSImageView(frame:NSRect(x:6,y:4,width:52,height:38))
  icon.imageScaling = .scaleProportionallyUpOrDown
  cell.imageView = icon
  cell.addSubview(icon)
  let name = NSTextField(labelWithString:"")
  name.frame = NSRect(x:68,y:13,width:580,height:21)
  name.autoresizingMask = [.width]
  name.lineBreakMode = .byTruncatingMiddle
  cell.textField = name
  cell.addSubview(name)
  return cell
 }

 func tableViewSelectionDidChange(_ notification:Notification) {
  updateCompressionPreview()
 }

 private func updateCompressionPreview() {
  let row = list.selectedRow
  removeFilesButton.isEnabled = !list.selectedRowIndexes.isEmpty
  guard files.indices.contains(row) else {
   compressionPreview.image = nil
   previewCaption.stringValue = "选择图片查看预览；从列表右侧或底部空白处拖动框选"
   return
  }
  let url = files[row]
  guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
        let image = thumbnail(source,edge:1200) else {
   compressionPreview.image = nil
   previewCaption.stringValue = "\(url.lastPathComponent) · 无法读取预览"
   return
  }
  compressionPreview.image = NSImage(cgImage:image,size:.zero)
  let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any]
  var width = props?[kCGImagePropertyPixelWidth] as? Int ?? image.width
  var height = props?[kCGImagePropertyPixelHeight] as? Int ?? image.height
  if (5...8).contains(props?[kCGImagePropertyOrientation] as? Int ?? 1) { swap(&width,&height) }
  let byteCount = (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
  let size = ByteCountFormatter.string(fromByteCount:Int64(byteCount),countStyle:.binary)
  previewCaption.stringValue = "\(url.lastPathComponent) · \(width) × \(height) 像素 · \(size)"
 }

 @objc private func removeSelectedFiles() {
  let selected = list.selectedRowIndexes
  guard !selected.isEmpty else { return }
  setFiles(files.enumerated().filter { !selected.contains($0.offset) }.map(\.element))
 }

 func tableView(_ tableView:NSTableView, writeRowsWith rowIndexes:IndexSet,to pasteboard:NSPasteboard) -> Bool {
  pasteboard.declareTypes([CompressionFileTable.rowType],owner:nil)
  return pasteboard.setString(rowIndexes.map(String.init).joined(separator:","),forType:CompressionFileTable.rowType)
 }

 func moveCompressionRows(_ selected:IndexSet, to slot:Int) -> Bool {
  guard let updated = movingFiles(files,selected:selected,to:slot) else { return false }
  setFiles(updated)
  return true
 }

 func tableView(_ tableView:NSTableView, validateDrop info:NSDraggingInfo,
                proposedRow row:Int, proposedDropOperation operation:NSTableView.DropOperation) -> NSDragOperation {
  if let source = info.draggingSource as? NSTableView, source === list,
     info.draggingPasteboard.string(forType:CompressionFileTable.rowType) != nil {
   tableView.setDropRow(max(0,row),dropOperation:.above)
   return .move
  }
  tableView.setDropRow(-1,dropOperation:.on)
  return Drop.fileURLs(from:info.draggingPasteboard).isEmpty ? [] : .copy
 }

 func tableView(_ tableView:NSTableView, acceptDrop info:NSDraggingInfo,
                row:Int, dropOperation:NSTableView.DropOperation) -> Bool {
  if let source = info.draggingSource as? NSTableView, source === list,
     let text = info.draggingPasteboard.string(forType:CompressionFileTable.rowType) {
   let indices = text.split(separator:",").compactMap { Int($0) }
   return moveCompressionRows(IndexSet(indices),to:row)
  }
  let urls = Drop.fileURLs(from:info.draggingPasteboard)
  guard !urls.isEmpty else { return false }
  addFiles(urls)
  return true
 }

 @objc func selectDestination() { let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.prompt = "选择"; if p.runModal() == .OK, let u = p.url { destination = u; pathLabel.stringValue = u.path } }
 @objc func start() {
  let urls = files; guard !urls.isEmpty else { status.stringValue = "请先添加图片。"; return }
  let output = destination; let w = Int(width.stringValue), h = Int(height.stringValue), kb = Int(size.stringValue)
  if [w,h,kb].contains(where: { if let n = $0 { return n <= 0 || n > 100000000 }; return false }) || [width,height,size].contains(where: { !$0.stringValue.isEmpty && Int($0.stringValue) == nil }) { status.stringValue = "请输入大于 0 的整数，或留空。"; return }
  status.stringValue = "正在试算并编码 \(urls.count) 张图片，请稍候…"
  DispatchQueue.global(qos:.userInitiated).async {
   var prepared: [(URL, Data, String, Int, Int)] = []; var failures:[String] = []
   for u in urls { do { let (data,ext,pw,ph) = try self.compress(u,w,h,kb); prepared.append((u,data,ext,pw,ph)) } catch { failures.append(u.lastPathComponent + "：" + error.localizedDescription) } }
   DispatchQueue.main.async {
    guard !prepared.isEmpty else { self.status.stringValue = "未能处理图片：" + failures.joined(separator:"；"); return }
    let lines = prepared.map { "\($0.0.lastPathComponent)：\($0.3) × \($0.4) 像素，约 \(String(format: "%.1f", Double($0.1.count)/1024)) KB" }
    let alert = NSAlert(); alert.messageText = "确认压缩结果"; alert.informativeText = lines.joined(separator:"\n") + (failures.isEmpty ? "" : "\n\n无法处理：\n" + failures.joined(separator:"\n")) + "\n\n确认后保存，原图保持不变。"; alert.addButton(withTitle:"保存结果"); alert.addButton(withTitle:"取消")
    guard alert.runModal() == .alertFirstButtonReturn else { self.status.stringValue = "已取消保存。"; return }
    var saved = 0; var saveFailures:[String] = []
    for (u,data,ext,_,_) in prepared { do { let dir = output ?? u.deletingLastPathComponent().appendingPathComponent("压缩结果",isDirectory:true); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true); let stem = u.deletingPathExtension().lastPathComponent; var dest = dir.appendingPathComponent("\(stem).\(ext)"); var n = 2; while FileManager.default.fileExists(atPath:dest.path) { dest = dir.appendingPathComponent("\(stem)-\(n).\(ext)"); n += 1 }; try data.write(to:dest,options:.atomic); saved += 1 } catch { saveFailures.append(u.lastPathComponent + "：" + error.localizedDescription) } }
    self.status.stringValue = "已保存 \(saved) 张。" + (saveFailures.isEmpty ? "" : "失败：" + saveFailures.joined(separator:"；"))
   }
  }
 }
 func compress(_ url:URL,_ w:Int?,_ h:Int?,_ kb:Int?) throws -> (Data, String, Int, Int) {
  func fail(_ s:String)->NSError { NSError(domain:"图片压缩",code:1,userInfo:[NSLocalizedDescriptionKey:s]) }
  guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), CGImageSourceGetCount(source) == 1, let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any], let ow = props[kCGImagePropertyPixelWidth] as? Int, let oh = props[kCGImagePropertyPixelHeight] as? Int else { throw fail("无法读取，或不支持动态图") }
  let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1; let swap = (5...8).contains(orientation); let dw = swap ? oh : ow, dh = swap ? ow : oh
  let png = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
  return try encodeWithinLimits(width: dw, height: dh, maxWidth: w, maxHeight: h, kilobytes: kb, png: png) { edge in
   let options: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: edge,
    kCGImageSourceShouldCacheImmediately: true
   ]
   return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
 }
}

func encodeWithinLimits(
 width: Int, height: Int, maxWidth: Int?, maxHeight: Int?, kilobytes: Int?, png: Bool,
 maximumQuality: Double = 1, minimumQuality: Double = 0.05, minimumEdge: Int = 1,
 render: (Int) -> CGImage?
) throws -> (Data, String, Int, Int) {
 let scale = min(1, Double(maxWidth ?? width) / Double(width), Double(maxHeight ?? height) / Double(height))
 var edge = max(1, Int(Double(max(width, height)) * scale))
 let smallestEdge = min(edge, minimumEdge)
 let limit = kilobytes.map { $0 * 1024 } ?? Int.max
 let format = png ? UTType.png : .jpeg
 func encode(_ image: CGImage, quality: Double) -> Data? {
  let buffer = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(buffer, format.identifier as CFString, 1, nil) else { return nil }
  let options = [kCGImageDestinationLossyCompressionQuality: quality]
  CGImageDestinationAddImage(destination, image, options as CFDictionary)
  return CGImageDestinationFinalize(destination) ? buffer as Data : nil
 }
 while true {
  guard let image = render(edge) else { throw encodingError("无法处理图片尺寸") }
  var result = encode(image, quality: maximumQuality).flatMap { $0.count <= limit ? $0 : nil }
  if !png, result == nil, minimumQuality < maximumQuality {
   var low = minimumQuality
   var high = maximumQuality
   for _ in 0..<9 {
    let quality = (low + high) / 2
    if let data = encode(image, quality: quality), data.count <= limit {
     result = data
     low = quality
    } else {
     high = quality
    }
   }
   if result == nil, let data = encode(image, quality: minimumQuality), data.count <= limit {
    result = data
   }
  }
  if let result { return (result, png ? "png" : "jpg", image.width, image.height) }
  if edge == smallestEdge {
   let message = minimumEdge > 1 ? "当前文件上限太小。请放宽上限，或手动指定更小的尺寸。" : "无法达到文件大小上限"
   throw encodingError(message)
  }
  edge = max(smallestEdge, Int(Double(edge) * 0.8))
 }
}

func encodingError(_ message: String) -> NSError {
 NSError(domain: "图片压缩", code: 1, userInfo: [NSLocalizedDescriptionKey: message])

}
struct PhotoEdit {
 var quarterTurns = 0
 var mirrorX = false
 var mirrorY = false
 var frameWidth = 1.0
 var frameHeight = 1.0
 var zoom = 1.0
 var offset = CGPoint.zero
}

enum FrameEdge { case left, right, top, bottom }

private final class EditablePreview: Drop {
 var selectPhoto: ((CGPoint) -> Bool)?
 var panPhoto: ((CGPoint) -> Void)?
 var menuForPhoto: (() -> NSMenu)?
 var resizePhoto: ((FrameEdge, CGPoint) -> Void)?
 var selectedFrame: CGRect? { didSet { needsDisplay = true } }
 var canvasSize = CGSize.zero
 private var resizing: FrameEdge?
 private var dragScale: CGFloat = 1
 private var previousViewPoint: CGPoint?

 private var displayedImageRect: CGRect {
  guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
  let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
  let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
  return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2,
                width: size.width, height: size.height)
 }

 private var selectedViewFrame: CGRect? {
  guard let frame = selectedFrame, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
  let rect = displayedImageRect
  return CGRect(x: rect.minX + frame.minX * rect.width / canvasSize.width,
                y: rect.minY + frame.minY * rect.height / canvasSize.height,
                width: frame.width * rect.width / canvasSize.width,
                height: frame.height * rect.height / canvasSize.height)
 }

 override func draw(_ dirtyRect: NSRect) {
  super.draw(dirtyRect)
  guard let frame = selectedViewFrame else { return }
  NSColor.white.withAlphaComponent(0.8).setStroke()
  let outline = NSBezierPath(rect: frame)
  outline.lineWidth = 1
  outline.stroke()
  let handles = [
   NSRect(x:frame.minX-3,y:frame.midY-10,width:6,height:20),
   NSRect(x:frame.maxX-3,y:frame.midY-10,width:6,height:20),
   NSRect(x:frame.midX-10,y:frame.minY-3,width:20,height:6),
   NSRect(x:frame.midX-10,y:frame.maxY-3,width:20,height:6)
  ]
  for rect in handles {
   let handle = NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3)
   NSColor.controlTextColor.setFill()
   handle.fill()
   NSColor.controlBackgroundColor.setStroke()
   handle.lineWidth = 1
   handle.stroke()
  }
 }

 override func resetCursorRects() {
  super.resetCursorRects()
  if let frame = selectedViewFrame {
   for x in [frame.minX,frame.maxX] {
    addCursorRect(NSRect(x:x-6,y:frame.minY,width:12,height:frame.height),cursor:.resizeLeftRight)
   }
   for y in [frame.minY,frame.maxY] {
    addCursorRect(NSRect(x:frame.minX,y:y-6,width:frame.width,height:12),cursor:.resizeUpDown)
   }
  }
 }

 private func edge(at point: CGPoint, of frame: CGRect) -> FrameEdge? {
  guard frame.insetBy(dx:-7,dy:-7).contains(point) else { return nil }
  if abs(point.x-frame.minX) <= 7 { return .left }
  if abs(point.x-frame.maxX) <= 7 { return .right }
  if abs(point.y-frame.maxY) <= 7 { return .top }
  if abs(point.y-frame.minY) <= 7 { return .bottom }
  return nil
 }

 private var previous: CGPoint?

 private func canvasPoint(_ event: NSEvent) -> CGPoint? {
  guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
  let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
  let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
  let point = convert(event.locationInWindow, from: nil)
  return CGPoint(x: (point.x - (bounds.width-size.width)/2)/size.width,
                 y: (point.y - (bounds.height-size.height)/2)/size.height)
 }
 override func mouseDown(with event: NSEvent) {
  let viewPoint = convert(event.locationInWindow, from: nil)
  if let frame = selectedViewFrame, let edge = edge(at:viewPoint,of:frame) {
   resizing = edge
   previousViewPoint = viewPoint
   dragScale = displayedImageRect.width / max(1, canvasSize.width)
   return
  }
  guard let point = canvasPoint(event) else { return }
  previous = selectPhoto?(point) == true ? point : nil
 }
 override func mouseDragged(with event: NSEvent) {
  if let resizing, let last = previousViewPoint {
   let point = convert(event.locationInWindow, from: nil)
   resizePhoto?(resizing, CGPoint(x:(point.x-last.x)/max(0.0001,dragScale),
                                  y:(point.y-last.y)/max(0.0001,dragScale)))
   previousViewPoint = point
   return
  }
  guard let point = canvasPoint(event), let previous else { return }
  panPhoto?(CGPoint(x: point.x-previous.x, y: point.y-previous.y))
  self.previous = point
 }
 override func mouseUp(with event: NSEvent) {
  previous = nil
  resizing = nil
  previousViewPoint = nil
 }
 override func rightMouseDown(with event: NSEvent) {
  guard let point = canvasPoint(event) else { return }
  guard selectPhoto?(point) == true else { return }
  if let menu = menuForPhoto?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
 }
}

private final class CollageThumbnail: NSButton {
 var remove: (() -> Void)?
 var editMenu: (() -> NSMenu)?
 var choose: ((NSEvent.ModifierFlags,Bool) -> Void)?
 override func rightMouseDown(with event: NSEvent) {
  choose?([],false)
  if let menu = editMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
 }
 private var pressLocation: NSPoint?
 override var acceptsFirstResponder: Bool { true }

 override func mouseDown(with event: NSEvent) {
  window?.makeFirstResponder(self)
  pressLocation = event.locationInWindow
  choose?(event.modifierFlags,false)
 }

 private func hasMoved(_ event: NSEvent) -> Bool {
  guard let pressLocation else { return false }
  return hypot(event.locationInWindow.x - pressLocation.x, event.locationInWindow.y - pressLocation.y) >= 4
 }

 override func mouseDragged(with event: NSEvent) {
  guard hasMoved(event), let strip = superview as? CollageThumbnailStrip else { return }
  alphaValue = 0.5
  strip.updateDrag(at: event.locationInWindow)
 }

 override func mouseUp(with event: NSEvent) {
  let moved = hasMoved(event)
  pressLocation = nil
  alphaValue = 1
  if !moved && event.modifierFlags.intersection([.command,.shift]).isEmpty { choose?([],true) }
  (superview as? CollageThumbnailStrip)?.finishDrag(from: tag, at: event.locationInWindow, moved: moved)
 }

 override func keyDown(with event: NSEvent) {
  switch event.keyCode {
  case 51, 117:
   if state != .on { sendAction(action, to: target) }
   remove?()
  default:
   super.keyDown(with: event)
  }
 }
}

private final class ImageDropScrollView: NSScrollView {
 var onFiles: (([URL]) -> Void)?
 override init(frame: NSRect) {
  super.init(frame: frame)
  registerForDraggedTypes([.fileURL])
 }
 required init?(coder: NSCoder) { fatalError() }
 override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
  Drop.fileURLs(from:sender.draggingPasteboard).isEmpty ? [] : .copy
 }
 override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
  let urls = Drop.fileURLs(from:sender.draggingPasteboard)
  guard !urls.isEmpty, let onFiles else { return false }
  onFiles(urls)
  return true
 }
}

private final class CollageThumbnailStrip: NSView {
 var moveItem: ((Int, Int) -> Bool)?
 var selectBox: ((CGRect,Bool) -> Void)?
 var deleteSelection: (() -> Void)?
 override var acceptsFirstResponder: Bool { true }
 override func mouseDown(with event:NSEvent) {
  window?.makeFirstResponder(self)
  let additive = !event.modifierFlags.intersection([.command,.shift]).isEmpty
  var first = true
  trackSelectionBox(in:self,event:event) { rect in
   self.selectBox?(rect,first && additive)
   first = false
  }
 }
 override func keyDown(with event:NSEvent) {
  if event.keyCode == 51 || event.keyCode == 117 { deleteSelection?() }
  else { super.keyDown(with:event) }
 }
 private let marker = CALayer()

 override init(frame: NSRect) {
  super.init(frame: frame)
  wantsLayer = true
  marker.cornerRadius = 1.5
  marker.isHidden = true
  layer?.addSublayer(marker)
 }

 required init?(coder: NSCoder) { fatalError() }

 func insertionIndex(at x: CGFloat) -> Int {
  subviews.compactMap { $0 as? CollageThumbnail }.filter { x >= $0.frame.midX }.count
 }

 func updateDrag(at windowPoint: NSPoint) {
  let point = convert(windowPoint, from: nil)
  guard visibleRect.contains(point) else { marker.isHidden = true; return }
  let x = point.x
  let visible = visibleRect
  if x > visible.maxX - 22, visible.maxX < bounds.maxX {
   scroll(NSPoint(x: min(bounds.maxX - visible.width, visible.minX + 18), y: visible.minY))
  } else if x < visible.minX + 22, visible.minX > 0 {
   scroll(NSPoint(x: max(0, visible.minX - 18), y: visible.minY))
  }
  let slot = insertionIndex(at: convert(windowPoint, from: nil).x)
  let buttons = subviews.compactMap { $0 as? CollageThumbnail }
  let markerX = slot == buttons.count ? (buttons.last?.frame.maxX ?? 8) + 4 : buttons[slot].frame.minX - 5
  CATransaction.begin()
  CATransaction.setDisableActions(true)
  marker.backgroundColor = NSColor.controlAccentColor.cgColor
  marker.frame = CGRect(x: markerX - 1.5, y: 22, width: 3, height: 69)
  marker.zPosition = 10
  marker.isHidden = false
  CATransaction.commit()
 }

 func finishDrag(from index: Int, at windowPoint: NSPoint, moved: Bool) {
  marker.isHidden = true
  let point = convert(windowPoint, from: nil)
  guard moved, visibleRect.contains(point) else { return }
  _ = moveItem?(index, insertionIndex(at: point.x))
 }

}

final class Collage: NSObject {
 var editFiles: (([URL]) -> Void)?
 var files:[URL]; var destination:URL?; var receiveFiles: (([URL]) -> Void)?; var chooseFiles:(()->Void)?; var clearFiles:(()->Void)?; let mode = NSPopUpButton(); let columns = NSTextField(string:"2"), gap = NSTextField(string:"10"), margin = NSTextField(string:"10"); let info = NSTextField(labelWithString:""); private let preview = EditablePreview(frame: NSRect(x: 20, y: 267, width: 680, height: 194))
 private let strip = ImageDropScrollView(frame: NSRect(x: 20, y: 505, width: 680, height: 111))
 private let thumbnails = CollageThumbnailStrip(frame: .zero)
 private var listedFiles: [URL] = []
 private var selectedFile: URL?
 private var selectedFiles = Set<URL>()
 private var marqueeBase = Set<URL>()
 private var thumbnailButtons: [CollageThumbnail] = []
 private var thumbnailImages: [URL: NSImage] = [:]
 private let moveLeftButton = NSButton(title: "左移", target: nil, action: nil)
 private let moveRightButton = NSButton(title: "右移", target: nil, action: nil)
 private let removeButton = NSButton(title: "×", target: nil, action: nil)
 private let selectionLabel = NSTextField(labelWithString: "空白处拖动框选，多选后可整组移动或移除")
 private var edits: [URL: PhotoEdit] = [:]
 private var previewLayout: CollageLayout?
 private var photoHeightCap: Int?
 private let zoomSlider = NSSlider(value: 100, minValue: 100, maxValue: 300, target: nil, action: nil)
 private let zoomValue = NSTextField(string: "100")
 private var editControls: [NSControl] = []
 private let outputWidth = NSTextField(string: "")
 private let outputHeight = NSTextField(string: "")
 private let outputSize = NSTextField(string: "")
 init(files:[URL],destination:URL?) { self.files = files; self.destination = destination }
 func makeView() -> NSView {
  let v = NSView(frame:NSRect(x:0,y:0,width:720,height:640))
  v.autoresizingMask = [.width,.height]
  strip.onFiles = { [weak self] in self?.receiveFiles?($0) }
  preview.resizePhoto = { [weak self] edge, delta in self?.resizeFrame(edge:edge,by:delta) }
  preview.onFiles = { [weak self] in self?.receiveFiles?($0) }
  preview.selectPhoto = { [weak self] in self?.selectPreview(at: $0) ?? false }
  preview.panPhoto = { [weak self] in self?.panPreview(by: $0) }
  preview.menuForPhoto = { [weak self] in self?.photoMenu() ?? NSMenu() }
  preview.autoresizingMask = [.width,.height]
  v.addSubview(preview)
  strip.autoresizingMask = [.width,.minYMargin]
  strip.hasHorizontalScroller = true
  strip.autohidesScrollers = true
  strip.borderType = .bezelBorder
  strip.drawsBackground = true
  strip.documentView = thumbnails
  v.addSubview(strip)
  selectionLabel.frame = NSRect(x: 20, y: 472, width: 417, height: 20)
  selectionLabel.autoresizingMask = [.minYMargin]
  selectionLabel.lineBreakMode = .byTruncatingMiddle
  selectionLabel.textColor = .secondaryLabelColor
  v.addSubview(selectionLabel)
  for (button, x, action) in [
   (moveLeftButton, 550.0, #selector(moveLeft)),
   (moveRightButton, 628.0, #selector(moveRight))
  ] {
   button.frame = NSRect(x: x, y: 466, width: 72, height: 31)
   button.target = self
   button.action = action
   button.autoresizingMask = [.minYMargin,.minXMargin]
   v.addSubview(button)
  }
  removeButton.target = self
  removeButton.action = #selector(removeSelected)
  removeButton.bezelStyle = .circular
  removeButton.toolTip = "移除所选图片（Delete 或 Backspace）"
  removeButton.setAccessibilityLabel("移除所选图片")
  thumbnails.selectBox = { [weak self] rect, preserve in self?.selectMarquee(rect,preserve:preserve) }
  thumbnails.deleteSelection = { [weak self] in self?.removeSelected() }
  thumbnails.moveItem = { [weak self] from, slot in self?.moveThumbnail(from: from, to: slot) ?? false }
  let zoomLabel = NSTextField(labelWithString: "放大")
  zoomLabel.frame = NSRect(x: 20, y: 237, width: 40, height: 20)
  v.addSubview(zoomLabel)
  zoomSlider.frame = NSRect(x: 65, y: 233, width: 205, height: 26)
  zoomSlider.target = self
  zoomSlider.action = #selector(changeZoom)
  zoomSlider.isContinuous = true
  zoomSlider.setAccessibilityLabel("照片放大百分比")
  v.addSubview(zoomSlider)
  zoomValue.frame = NSRect(x: 280, y: 233, width: 55, height: 25)
  zoomValue.target = self
  zoomValue.action = #selector(typeZoom)
  zoomValue.setAccessibilityLabel("放大百分比")
  v.addSubview(zoomValue)
  let percent = NSTextField(labelWithString: "%")
  percent.frame = NSRect(x: 338, y: 237, width: 20, height: 20)
  v.addSubview(percent)
  editControls = [zoomSlider, zoomValue]
  for (title, x, tag) in [("左转90°", 20.0, 0), ("右转90°", 130.0, 1),
                           ("旋转180°", 240.0, 2), ("水平镜像", 350.0, 3),
                           ("垂直镜像", 460.0, 4), ("还原", 570.0, 5)] {
   let button = NSButton(title: title, target: self, action: #selector(applyEdit(_:)))
   button.tag = tag
   button.frame = NSRect(x: x, y: 202, width: 104, height: 29)
   editControls.append(button)
   v.addSubview(button)
  }
  let panHint = NSTextField(labelWithString: "拖动照片取景，拖四边调整画框")
  panHint.frame = NSRect(x: 367, y: 237, width: 330, height: 20)
  panHint.font = .systemFont(ofSize: 12)
  panHint.textColor = .secondaryLabelColor
  v.addSubview(panHint)
  updateSelection()
  mode.frame = NSRect(x:20,y:170,width:120,height:28); mode.addItems(withTitles:["竖直排列","水平排列","网格排列"]); mode.target = self; mode.action = #selector(refresh); v.addSubview(mode)
  func label(_ str:String,_ x:CGFloat) { let l = NSTextField(labelWithString:str); l.frame = NSRect(x:x,y:175,width:45,height:20); v.addSubview(l) }
  label("列数",155); label("间距",290); label("边距",425)
  for (f,x) in [(columns,200.0),(gap,335.0),(margin,470.0)] { f.frame = NSRect(x:x,y:170,width:75,height:25); f.target = self; f.action = #selector(refresh); v.addSubview(f) }
  let update = NSButton(title:"更新预览",target:self,action:#selector(refresh)); update.frame = NSRect(x:565,y:168,width:110,height:30); v.addSubview(update)
  let add = NSButton(title:"添加图片",target:self,action:#selector(addImages)); add.frame = NSRect(x:20,y:70,width:100,height:32); v.addSubview(add)
  let clear = NSButton(title:"清空图片",target:self,action:#selector(clearImages)); clear.frame = NSRect(x:125,y:70,width:100,height:32); v.addSubview(clear)
  let save = NSButton(title:"导出拼图…",target:self,action:#selector(exportImage)); save.frame = NSRect(x:230,y:70,width:120,height:32); v.addSubview(save)
  for (field, title, x) in [(outputWidth, "最大宽度（像素）", 20.0),
                             (outputHeight, "最大高度（像素）", 240.0),
                             (outputSize, "文件上限（KB）", 460.0)] {
   let label = NSTextField(labelWithString: title)
   label.frame = NSRect(x: x, y: 141, width: 180, height: 18)
   field.frame = NSRect(x: x, y: 115, width: 170, height: 24)
   field.placeholderString = "不限制"
   if field !== outputSize { field.target = self; field.action = #selector(dimensionsChanged) }
   v.addSubview(label)
   v.addSubview(field)
  }
  let compressed = NSButton(title: "压缩并导出…", target: self, action: #selector(exportCompressed))
  compressed.frame = NSRect(x: 360, y: 70, width: 140, height: 32)
  v.addSubview(compressed)
  info.frame = NSRect(x:20,y:43,width:680,height:22)
  info.lineBreakMode = .byTruncatingTail
  v.addSubview(info)
  let hint = NSTextField(labelWithString:"照片以首图高度为基准等高排列，宽度随各图比例变化。宽高上限包含间距和边距。修改设置后按回车更新预览。"); hint.frame = NSRect(x:20,y:7,width:680,height:32); hint.maximumNumberOfLines = 2; hint.font = NSFont.systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; v.addSubview(hint)
  info.stringValue = "请添加图片。"; return v
 }
 @objc func addImages() { chooseFiles?() }
 @objc func clearImages() { clearFiles?() }
 private func updateThumbnails() {
  guard listedFiles != files else { return }
  if listedFiles.first != files.first { photoHeightCap = nil }
  listedFiles = files
  if let selectedFile, !files.contains(selectedFile) { self.selectedFile = nil }
  selectedFiles.formIntersection(Set(files))
  let retained = Set(files)
  edits = edits.filter { retained.contains($0.key) }
  thumbnailImages = thumbnailImages.filter { retained.contains($0.key) }
  thumbnailButtons.removeAll()
  thumbnails.subviews.forEach { $0.removeFromSuperview() }
  thumbnails.frame = NSRect(x: 0, y: 0, width: max(strip.contentSize.width, CGFloat(files.count) * 115 + 8), height: max(93,strip.contentSize.height))
  for (index, url) in files.enumerated() {
   let x = CGFloat(index) * 115 + 8
   let button = CollageThumbnail(frame: NSRect(x: x, y: 23, width: 104, height: 68))
   button.choose = { [weak self] modifiers, collapse in self?.chooseThumbnail(index,modifiers:modifiers,collapse:collapse) }
   button.remove = { [weak self] in self?.removeSelected() }
   button.editMenu = { [weak self] in self?.photoMenu() ?? NSMenu() }
   button.setButtonType(.pushOnPushOff)
   button.isBordered = false
   button.imageScaling = .scaleProportionallyUpOrDown
   button.focusRingType = .none
   button.target = self
   button.action = #selector(selectThumbnail(_:))
   button.tag = index
   button.toolTip = url.lastPathComponent
   button.setAccessibilityLabel("第 \(index + 1) 张，\(url.lastPathComponent)")
   if thumbnailImages[url] == nil,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let icon = thumbnail(source, edge: 220) {
    thumbnailImages[url] = NSImage(cgImage: icon, size: .zero)
   }
   if let image = thumbnailImages[url] {
    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let edited = orientedPhoto(cg, edit: edits[url] ?? PhotoEdit()) {
     button.image = NSImage(cgImage: edited, size: .zero)
    } else { button.image = image }
    button.imagePosition = .imageOnly
   } else {
    button.title = "预览不可用"
   }
   thumbnails.addSubview(button)
   thumbnailButtons.append(button)

   let label = NSTextField(labelWithString: "\(index + 1). \(url.lastPathComponent)")
   label.frame = NSRect(x: x, y: 4, width: 104, height: 17)
   label.lineBreakMode = .byTruncatingMiddle
   label.font = .systemFont(ofSize: 11)
   label.toolTip = url.lastPathComponent
   thumbnails.addSubview(label)
  }
  thumbnails.addSubview(removeButton)
  strip.reflectScrolledClipView(strip.contentView)
  updateSelection()
 }

 private var selectedIndex: Int? {
  selectedFile.flatMap { files.firstIndex(of: $0) }
 }

 private func updateSelection() {
  let index = selectedIndex
  updatePreviewHandle()
  let zoom = selectedFile.flatMap { edits[$0]?.zoom } ?? 1
  zoomSlider.doubleValue = zoom * 100
  zoomValue.integerValue = Int((zoom * 100).rounded())
  editControls.forEach { $0.isEnabled = index != nil }
  for (position, button) in thumbnailButtons.enumerated() {
   let selected = selectedFiles.contains(files[position])
   button.state = selected ? .on : .off
   button.alphaValue = !selectedFiles.isEmpty && !selected ? 0.55 : 1
  }
  let selectedPositions = files.indices.filter { selectedFiles.contains(files[$0]) }
  moveLeftButton.isEnabled = selectedPositions.first.map { $0 > 0 } ?? false
  moveRightButton.isEnabled = selectedPositions.last.map { $0 < files.count - 1 } ?? false
  removeButton.isHidden = index == nil
  removeButton.isEnabled = index != nil
  if let index {
   selectionLabel.stringValue = selectedFiles.count > 1
    ? "已选 \(selectedFiles.count) 张 · 拖动可整组移动，Delete 移除"
    : "已选第 \(index + 1) 张 · \(files[index].lastPathComponent)"
   if thumbnailButtons.indices.contains(index) {
    let frame = thumbnailButtons[index].frame
    removeButton.frame = NSRect(x: frame.maxX - 23, y: frame.maxY - 24, width: 23, height: 23)
    // Scrolling is driven by direct navigation and dragging, not selection updates.
   }
  } else {
   selectionLabel.stringValue = "空白处拖动框选，多选后可整组移动或移除"
  }
 }

 @objc private func selectThumbnail(_ button:NSButton) {
  chooseThumbnail(button.tag,modifiers:[],collapse:false)
 }

 private func chooseThumbnail(_ index:Int, modifiers:NSEvent.ModifierFlags, collapse:Bool) {
  guard files.indices.contains(index) else { return }
  let url = files[index]
  if modifiers.contains(.shift), let anchor = selectedIndex {
   selectedFiles.formUnion(files[min(anchor,index)...max(anchor,index)])
  } else if modifiers.contains(.command) {
   if !selectedFiles.insert(url).inserted { selectedFiles.remove(url) }
  } else if collapse || !selectedFiles.contains(url) {
   selectedFiles = [url]
  }
  selectedFile = selectedFiles.contains(url) ? url : files.first(where:{ selectedFiles.contains($0) })
  updateSelection()
 }

 private func selectMarquee(_ rect:CGRect,preserve:Bool) {
  if rect.size == .zero { marqueeBase = preserve ? selectedFiles : [] }
  let hits = thumbnailButtons.filter { $0.frame.intersects(rect) && rect.width > 0 && rect.height > 0 }
  selectedFiles = marqueeBase.union(hits.map { files[$0.tag] })
  selectedFile = files.first(where:{ selectedFiles.contains($0) })
  updateSelection()
 }

 private func photoMenu() -> NSMenu {
  let menu = NSMenu()
  for (index, title) in ["左转90°", "右转90°", "旋转180°", "水平镜像", "垂直镜像", "还原"].enumerated() {
   let item = NSMenuItem(title: title, action: #selector(applyEdit(_:)), keyEquivalent: "")
   item.tag = index
   item.target = self
   menu.addItem(item)
  }
  menu.addItem(.separator())
  let remove = NSMenuItem(title: "移除所选图片", action: #selector(removeSelected), keyEquivalent: "")
  remove.target = self
  menu.addItem(remove)
  return menu
 }

 @objc private func applyEdit(_ sender: AnyObject) {
  guard let url = selectedFile else { return }
  let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? -1
  var edit = edits[url] ?? PhotoEdit()
  switch tag {
  case 0: edit.quarterTurns = (edit.quarterTurns + 1) % 4; edit.offset = .zero
  case 1: edit.quarterTurns = (edit.quarterTurns + 3) % 4; edit.offset = .zero
  case 2: edit.quarterTurns = (edit.quarterTurns + 2) % 4; edit.offset = .zero
  case 3: edit.mirrorX.toggle()
  case 4: edit.mirrorY.toggle()
  case 5: edit = PhotoEdit()
  default: return
  }
  edits[url] = edit
  photoHeightCap = nil
  listedFiles = []
  refresh()
  updateSelection()
 }

 @objc private func changeZoom() { setZoom(zoomSlider.doubleValue / 100) }
 @objc private func typeZoom() { setZoom(zoomValue.doubleValue / 100) }

 private func setZoom(_ value: Double) {
  guard let url = selectedFile else { return }
  var edit = edits[url] ?? PhotoEdit()
  edit.zoom = min(3, max(1, value.isFinite ? value : 1))
  if edit.zoom == 1 && edit.frameWidth == 1 && edit.frameHeight == 1 { edit.offset = .zero }
  edits[url] = edit
  refresh()
  updateSelection()
 }

 private func selectPreview(at normalized: CGPoint) -> Bool {
  guard let layout = previewLayout else { return false }
  let point = CGPoint(x: normalized.x * Double(layout.width), y: normalized.y * Double(layout.height))
  guard let index = layout.frames().firstIndex(where: { $0.contains(point) }) else { return false }
  selectedFile = files[index]
  selectedFiles = [files[index]]
  updateSelection()
  return true
 }

 private func updatePreviewHandle() {
  preview.canvasSize = previewLayout.map { CGSize(width:$0.width,height:$0.height) } ?? .zero
  if let index = selectedIndex, let layout = previewLayout, layout.frames().indices.contains(index) {
   preview.selectedFrame = layout.frames()[index]
  } else {
   preview.selectedFrame = nil
  }
  preview.window?.invalidateCursorRects(for:preview)
 }

 private func resizeFrame(edge: FrameEdge, by delta: CGPoint) {
  guard let url = selectedFile, let index = selectedIndex, let layout = previewLayout else { return }
  let frame = layout.frames()[index]
  var edit = edits[url] ?? PhotoEdit()
  photoHeightCap = layout.photoBaseline
  switch edge {
  case .left, .right:
   let originalWidth = frame.width / edit.frameWidth
   let oldOverflow = (originalWidth * edit.zoom - frame.width)/2
   let change = edge == .right ? delta.x : -delta.x
   edit.frameWidth = min(1,max(0.15,edit.frameWidth + change/originalWidth))
   let newWidth = originalWidth * edit.frameWidth
   let newOverflow = (originalWidth * edit.zoom - newWidth)/2
   let shift = (frame.width-newWidth)/2 * (edge == .right ? 1.0 : -1.0)
   edit.offset.x = newOverflow > 0 ? min(1,max(-1,(edit.offset.x*oldOverflow+shift)/newOverflow)) : 0
  case .top, .bottom:
   let originalHeight = frame.height / edit.frameHeight
   let oldOverflow = (originalHeight * edit.zoom - frame.height)/2
   let change = edge == .top ? delta.y : -delta.y
   edit.frameHeight = min(1,max(0.15,edit.frameHeight + change/originalHeight))
   let newHeight = originalHeight * edit.frameHeight
   let newOverflow = (originalHeight * edit.zoom - newHeight)/2
   let shift = (frame.height-newHeight)/2 * (edge == .top ? 1.0 : -1.0)
   edit.offset.y = newOverflow > 0 ? min(1,max(-1,(edit.offset.y*oldOverflow+shift)/newOverflow)) : 0
  }
  edits[url] = edit
  refresh()
 }

 private func panPreview(by delta: CGPoint) {
  guard let url = selectedFile, let index = selectedIndex, let layout = previewLayout else { return }
  var edit = edits[url] ?? PhotoEdit()
  let frame = layout.frames()[index]
  let horizontalOverflow = frame.width * (edit.zoom/edit.frameWidth - 1) / 2
  let verticalOverflow = frame.height * (edit.zoom/edit.frameHeight - 1) / 2
  if horizontalOverflow > 0 {
   edit.offset.x = min(1,max(-1,edit.offset.x + delta.x * Double(layout.width)/horizontalOverflow))
  }
  if verticalOverflow > 0 {
   edit.offset.y = min(1,max(-1,edit.offset.y + delta.y * Double(layout.height)/verticalOverflow))
  }
  edits[url] = edit
  refresh()
 }

 @objc private func moveLeft() { moveSelected(by: -1) }
 @objc private func moveRight() { moveSelected(by: 1) }

 private func moveSelected(by offset:Int) {
  guard let index = selectedIndex else { return }
  let selected = files.indices.filter { selectedFiles.contains(files[$0]) }
  guard let first = selected.first, let last = selected.last else { return }
  let slot = offset < 0 ? first-1 : last+2
  guard (0...files.count).contains(slot) else { return }
  moveThumbnail(from:index,to:slot)
 }

 @discardableResult
 private func moveThumbnail(from index: Int, to slot: Int) -> Bool {
  guard files.indices.contains(index), (0...files.count).contains(slot), let editFiles else { return false }
  if !selectedFiles.contains(files[index]) { selectedFiles = [files[index]] }
  let indices = IndexSet(files.indices.filter { selectedFiles.contains(files[$0]) })
  guard let updated = movingFiles(files,selected:indices,to:slot) else { return false }
  selectedFile = files[index]
  editFiles(updated)
  focusSelection()
  return true
 }

 private func focusSelection() {
  guard let index = selectedIndex, thumbnailButtons.indices.contains(index) else { return }
  thumbnails.window?.makeFirstResponder(thumbnailButtons[index])
 }

 @objc private func removeSelected() {
  guard let index = selectedIndex, !selectedFiles.isEmpty else { return }
  let updated = files.filter { !selectedFiles.contains($0) }
  selectedFile = updated.isEmpty ? nil : updated[min(index,updated.count-1)]
  selectedFiles = selectedFile.map { [$0] } ?? []
  editFiles?(updated)
  focusSelection()
 }
 @objc private func dimensionsChanged() {
  photoHeightCap = nil
  refresh()
 }
 @objc func refresh() {
  updateThumbnails()
  preview.image = nil
  previewLayout = nil
  if files.isEmpty { photoHeightCap = nil }
  updatePreviewHandle()
  guard !files.isEmpty else { info.stringValue = "请添加图片，可一次拖入多张。"; return }
  do {
   let layout = try makeLayout()
   previewLayout = layout
   let image = try layout.render(previewEdge: 1000)
   preview.image = NSImage(cgImage: image, size: .zero)
   updatePreviewHandle()
   info.stringValue = "结果：\(layout.width) × \(layout.height) 像素，共 \(files.count) 张。" +
    (layout.isScaled ? " 已按尺寸限制缩放图片。" : "")
  } catch {
   info.stringValue = error.localizedDescription
  }
 }

 private func makeLayout() throws -> CollageLayout {
  guard !files.isEmpty else { throw encodingError("请先添加图片。") }
  guard let col = Int(columns.stringValue), (1...100).contains(col),
        let gap = Int(gap.stringValue), (0...10000).contains(gap),
        let margin = Int(margin.stringValue), (0...10000).contains(margin)
  else { throw encodingError("列数须为 1–100，间距和边距须为 0–10000 像素。") }
  let cols: Int
  switch mode.indexOfSelectedItem {
  case 0: cols = 1
  case 1: cols = files.count
  default: cols = min(col, files.count)
  }
  return try CollageLayout(files: files, columns: cols, gap: gap, margin: margin,
                           maxWidth: try outputLimit(outputWidth), maxHeight: try outputLimit(outputHeight), edits: edits, photoHeightCap: photoHeightCap)
 }
 @objc func exportImage() {
  let image: CGImage
  do {
   image = try makeLayout().render()
  } catch {
   info.stringValue = error.localizedDescription
   return
  }
  let panel = savePanel(format: .png)
  guard panel.runModal() == .OK, let url = panel.url else { return }
  guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
   info.stringValue = "无法保存文件。"
   return
  }
  CGImageDestinationAddImage(output, image, nil)
  info.stringValue = CGImageDestinationFinalize(output) ? "已保存：\(url.lastPathComponent)" : "保存失败。"
 }

 private func outputLimit(_ field: NSTextField) throws -> Int? {
  let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty { return nil }
  guard let limit = Int(value), (1...100_000_000).contains(limit) else {
   throw encodingError("宽度、高度及文件上限须为正整数，也可以留空。")
  }
  return limit
 }

 @objc func exportCompressed() {
  let layout: CollageLayout
  let fileLimit: Int?
  do {
   layout = try makeLayout()
   fileLimit = try outputLimit(outputSize)
  } catch {
   info.stringValue = error.localizedDescription
   return
  }
  let review = JPEGExportReview()
  guard let data = review.chooseQuality(layout: layout, fileLimit: fileLimit) else {
   info.stringValue = "已取消导出。"
   return
  }
  let panel = savePanel(format: .jpeg)
  panel.message = review.summary.stringValue
  guard panel.runModal() == .OK, let url = panel.url else {
   info.stringValue = "已取消导出。"
   return
  }
  do {
   try data.write(to: url, options: .atomic)
   info.stringValue = "已保存：\(url.lastPathComponent)"
  } catch {
   info.stringValue = error.localizedDescription
  }
 }

 private func savePanel(format: UTType) -> NSSavePanel {
  let panel = NSSavePanel()
  panel.allowedContentTypes = [format]
  panel.nameFieldStringValue = format == .png ? "拼图.png" : "拼图-压缩.jpg"
  panel.directoryURL = destination
  return panel
 }
}
private final class JPEGExportReview: NSObject {
 private let qualities: [Double] = [1, 0.85, 0.70, 0.55]
 private let qualityPicker = NSPopUpButton(frame: NSRect(x: 0, y: 60, width: 245, height: 28))
 let summary = NSTextField(wrappingLabelWithString: "")
 private var continueButton: NSButton?
 private var data: Data?
 private var encode: ((Double) throws -> (Data, String, Int, Int))?
 private var active = false

 func chooseQuality(layout: CollageLayout, fileLimit: Int?) -> Data? {
  encode = { quality in
   try encodeWithinLimits(width: layout.width, height: layout.height,
                          maxWidth: nil, maxHeight: nil, kilobytes: fileLimit, png: false,
                          maximumQuality: quality, minimumQuality: 0.55,
                          minimumEdge: max(640, layout.minimumEdge)) { edge in
    try? layout.render(maxEdge: edge)
   }
  }
  let alert = NSAlert()
  alert.messageText = "拼图导出质量"
  alert.informativeText = "选择 JPEG 质量，查看编码后的实际尺寸和文件大小。"
  continueButton = alert.addButton(withTitle: "选择保存位置…")
  alert.addButton(withTitle: "取消")

  let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 325, height: 90))
  qualityPicker.addItems(withTitles: ["最高 · 100%", "高 · 85%（推荐）", "中 · 70%", "低 · 55%"])
  qualityPicker.selectItem(at: 1)
  qualityPicker.setAccessibilityLabel("JPEG 质量")
  qualityPicker.target = self
  qualityPicker.action = #selector(updatePreview)
  accessory.addSubview(qualityPicker)
  summary.frame = NSRect(x: 2, y: 4, width: 321, height: 46)
  summary.maximumNumberOfLines = 2
  accessory.addSubview(summary)
  alert.accessoryView = accessory

  active = true
  updatePreview()
  let choice = alert.runModal()
  active = false
  return choice == .alertFirstButtonReturn ? data : nil
 }

 @objc private func updatePreview() {
  guard let encode else { return }
  let quality = qualities[qualityPicker.indexOfSelectedItem]
  data = nil
  continueButton?.isEnabled = false
  qualityPicker.isEnabled = false
  summary.stringValue = "正在试算…"
  DispatchQueue.global(qos: .userInitiated).async { [weak self] in
   let result = Result { try encode(quality) }
   DispatchQueue.main.async { [weak self] in
    guard let self, self.active else { return }
    self.qualityPicker.isEnabled = true
    switch result {
    case let .success((data, _, width, height)):
     self.data = data
     let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
     self.summary.stringValue = "JPEG · \(width) × \(height) 像素 · \(size)"
     self.continueButton?.isEnabled = true
    case let .failure(error):
     self.summary.stringValue = error.localizedDescription
    }
   }
  }
 }
}

private func thumbnail(_ source: CGImageSource, edge: Int) -> CGImage? {
 let options: [CFString: Any] = [
  kCGImageSourceCreateThumbnailFromImageAlways: true,
  kCGImageSourceCreateThumbnailWithTransform: true,
  kCGImageSourceThumbnailMaxPixelSize: edge
 ]
 return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func orientedPhoto(_ image: CGImage, edit: PhotoEdit) -> CGImage? {
 guard edit.quarterTurns != 0 || edit.mirrorX || edit.mirrorY else { return image }
 let swap = edit.quarterTurns % 2 == 1
 let width = swap ? image.height : image.width
 let height = swap ? image.width : image.height
 guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
 context.translateBy(x: Double(width)/2, y: Double(height)/2)
 context.scaleBy(x: edit.mirrorX ? -1 : 1, y: edit.mirrorY ? -1 : 1)
 context.rotate(by: Double(edit.quarterTurns) * .pi/2)
 let rect = CGRect(x: -CGFloat(image.width)/2, y: -CGFloat(image.height)/2,
                   width: CGFloat(image.width), height: CGFloat(image.height))
 context.draw(image, in: rect)
 return context.makeImage()
}

struct CollageLayout {
 let files: [URL]
 let gap: Int
 let margin: Int
 private struct Geometry {
  let ratio: Double
  let heightFactor: Double
 }
 private let rows: [[Geometry]]
 private let edits: [URL: PhotoEdit]
 private let firstHeight: Int
 private let photoHeight: Int

 var width: Int { canvas(at: photoHeight).width }
 var height: Int { canvas(at: photoHeight).height }
 var minimumEdge: Int {
  let size = canvas(at: 1)
  return max(size.width, size.height)
 }
 var photoBaseline: Int { photoHeight }
 var isScaled: Bool { photoHeight < firstHeight }

 init(files: [URL], columns: Int, gap: Int, margin: Int, maxWidth: Int? = nil, maxHeight: Int? = nil, edits: [URL: PhotoEdit] = [:], photoHeightCap: Int? = nil) throws {
  guard !files.isEmpty, columns > 0 else { throw encodingError("请先添加图片。") }
  let sizes = try files.map { url -> (width: Int, height: Int) in
   guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
         CGImageSourceGetCount(source) == 1,
         let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
         let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0,
         let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0
   else { throw encodingError("无法读取图片或不支持动态图：\(url.lastPathComponent)") }
   let rotated = (5...8).contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
   let size = rotated ? (height, width) : (width, height)
   return (edits[url]?.quarterTurns ?? 0) % 2 == 1 ? (size.1, size.0) : size
  }
  let ratios = zip(files,sizes).map { url, size in
   Geometry(ratio:Double(size.width) / Double(size.height) * (edits[url]?.frameWidth ?? 1),
            heightFactor:edits[url]?.frameHeight ?? 1)
  }
  let rows = stride(from: 0, to: ratios.count, by: columns).map { start in
   Array(ratios[start..<min(start + columns, ratios.count)])
  }
  let widthLimit = min(maxWidth ?? 30_000, 30_000)
  let heightLimit = min(maxHeight ?? 30_000, 30_000)
  func fits(_ height: Int) -> Bool {
   let size = Self.canvas(rows: rows, gap: gap, margin: margin, photoHeight: height)
   return size.width <= widthLimit && size.height <= heightLimit && size.width * size.height <= 80_000_000
  }
  guard fits(1) else {
   throw encodingError("当前尺寸放不下设定的间距和边距。请增大尺寸上限，或减少留白。")
  }

  self.files = files
  self.edits = edits
  self.rows = rows
  self.gap = gap
  self.margin = margin
  firstHeight = sizes[0].height
  photoHeight = Self.largestPhotoHeight(upTo: min(sizes[0].height, heightLimit, photoHeightCap ?? sizes[0].height), fits: fits)
 }

 private static func largestPhotoHeight(upTo limit: Int, fits: (Int) -> Bool) -> Int {
  var lower = 1
  var upper = limit
  while lower < upper {
   let middle = lower + (upper - lower + 1) / 2
   if fits(middle) { lower = middle } else { upper = middle - 1 }
  }
  return lower
 }

 private static func photoWidth(_ ratio: Double, height: Int) -> Int {
  max(1, Int((ratio * Double(height)).rounded()))
 }

 private static func rowWidth(_ row: [Geometry], gap: Int, photoHeight: Int) -> Int {
  row.reduce(gap * (row.count - 1)) { total, ratio in
   total + photoWidth(ratio.ratio, height: photoHeight)
  }
 }

 private static func rowHeight(_ row: [Geometry], photoHeight:Int) -> Int {
  row.map { max(1,Int((Double(photoHeight)*$0.heightFactor).rounded())) }.max() ?? 1
 }

 private static func canvas(rows: [[Geometry]], gap: Int, margin: Int, photoHeight: Int) -> (width: Int, height: Int) {
  let widest = rows.map { rowWidth($0, gap: gap, photoHeight: photoHeight) }.max() ?? 0
  let rowsHeight = rows.reduce(0) { $0 + rowHeight($1, photoHeight:photoHeight) }
  return (widest + 2 * margin, rowsHeight + gap * (rows.count - 1) + 2 * margin)
 }

 private func canvas(at height: Int) -> (width: Int, height: Int) {
  Self.canvas(rows: rows, gap: gap, margin: margin, photoHeight: height)
 }

 func frames() -> [CGRect] { frames(at: photoHeight) }

 private func frames(at height: Int) -> [CGRect] {
  let size = canvas(at: height)
  var result: [CGRect] = []
  var top = size.height - margin
  for row in rows {
   var x = margin
   for ratio in row {
    let width = Self.photoWidth(ratio.ratio, height: height)
    let frameHeight = max(1,Int((Double(height)*ratio.heightFactor).rounded()))
    result.append(CGRect(x:x,y:top-frameHeight,width:width,height:frameHeight))
    x += width + gap
   }
   top -= Self.rowHeight(row,photoHeight:height) + gap
  }
  return result
 }

 func render(maxEdge: Int? = nil, previewEdge: Int? = nil) throws -> CGImage {
  let height: Int
  if let maxEdge {
   guard maxEdge >= minimumEdge else { throw encodingError("画布太小，无法保留间距和边距。") }
   height = Self.largestPhotoHeight(upTo: photoHeight) { height in
    let size = canvas(at: height)
    return max(size.width, size.height) <= maxEdge
   }
  } else {
   height = photoHeight
  }
  let (canvasWidth, canvasHeight) = canvas(at: height)
  let displayScale = min(1, Double(previewEdge ?? max(canvasWidth, canvasHeight)) / Double(max(canvasWidth, canvasHeight)))
  let outputWidth = max(1, Int((Double(canvasWidth) * displayScale).rounded()))
  let outputHeight = max(1, Int((Double(canvasHeight) * displayScale).rounded()))
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: outputWidth, height: outputHeight,
                                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw encodingError("无法创建拼图画布。") }
  context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
  context.interpolationQuality = .high
  context.scaleBy(x: Double(outputWidth) / Double(canvasWidth), y: Double(outputHeight) / Double(canvasHeight))
  for (index, frame) in frames(at: height).enumerated() {
   let url = files[index]
   let edit = edits[url] ?? PhotoEdit()
   try autoreleasepool {
    let decodeEdge = max(1, Int(ceil(max(frame.width/edit.frameWidth, frame.height/edit.frameHeight) * displayScale * edit.zoom)))
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let decoded = thumbnail(source, edge: decodeEdge),
          let image = orientedPhoto(decoded, edit: edit)
    else { throw encodingError("无法读取图片：\(url.lastPathComponent)") }
    let width = frame.width * edit.zoom / edit.frameWidth
    let height = frame.height * edit.zoom / edit.frameHeight
    let rect = CGRect(x: frame.midX - width/2 + edit.offset.x * (width-frame.width)/2,
                      y: frame.midY - height/2 + edit.offset.y * (height-frame.height)/2,
                      width: width, height: height)
    context.saveGState()
    context.clip(to: frame)
    context.draw(image, in: rect)
    context.restoreGState()
   }
  }
  guard let image = context.makeImage() else { throw encodingError("无法生成拼图。") }
  return image
 }
}
let app = NSApplication.shared; let delegate = App(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
