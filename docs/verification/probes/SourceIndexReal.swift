import Foundation
import CryptoKit
import CoreGraphics
import CoreText
import MeetingCore
enum ProbeFailure: Error { case check(String) }
@main struct Probe {
 static func main() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-source-proof-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let db = root.appendingPathComponent("sources.sqlite")
  let meeting = root.appendingPathComponent("项目会议.md")
  let lunch = root.appendingPathComponent("午餐.txt")
  let travel = root.appendingPathComponent("旅行.pdf")
  try Data("明天下午三点讨论项目预算，总金额是两万五千元，请王明准备方案。".utf8).write(to:meeting)
  try Data("今天中午去食堂吃面条和青菜。".utf8).write(to:lunch)
  var box=CGRect(x:0,y:0,width:600,height:800)
  guard let pdf=CGContext(travel as CFURL,mediaBox:&box,nil) else { throw ProbeFailure.check("Cannot create synthetic PDF") }
  pdf.beginPDFPage(nil);pdf.textPosition=CGPoint(x:40,y:720)
  let font=CTFontCreateWithName("PingFangSC-Regular" as CFString,18,nil)
  let line=CTLineCreateWithAttributedString(NSAttributedString(string:"周末坐火车去海边度假，预订两晚酒店。",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font]))
  CTLineDraw(line,pdf);pdf.endPDFPage();pdf.closePDF()
  let index=try SourceIndex(databaseURL:db)
  var owned:SourceIndex?=index
  do {
   let first=try await index.ingest(file:meeting,accountScope:"synthetic-local")
   let second=try await index.ingest(file:lunch,accountScope:"synthetic-local")
   let third=try await index.ingest(file:travel,accountScope:"synthetic-local")
   let ids:Set<String>=[first.id,second.id,third.id]
   let scopes:Set<String>=["synthetic-local"]
   let duplicate=try await index.ingest(file:meeting,accountScope:"synthetic-local")
   guard duplicate.activeRevisionID==first.activeRevisionID else { throw ProbeFailure.check("Duplicate revision changed") }
   let pdfDetail=try await index.detail(sourceID:third.id)
   guard pdfDetail?.text?.contains("海边") == true,pdfDetail?.chunks.first?.anchor.page == 1 else { throw ProbeFailure.check("Native PDF snapshot/anchor failed") }
   let hits=try await index.search("明天下午讨论什么预算，谁准备方案？",sourceIDs:ids,accountScopes:scopes)
   guard hits.first?.sourceID==first.id else { throw ProbeFailure.check("Actual persisted Chinese retrieval failed") }
   try Data("后天上午评审新预算四万元，请李华准备报告。".utf8).write(to:meeting)
   let stable=try await index.detail(sourceID:first.id)
   guard stable?.text?.contains("两万五千元") == true else { throw ProbeFailure.check("File change mutated snapshot") }
   let revised=try await index.ingest(file:meeting,accountScope:"synthetic-local")
   guard revised.activeRevisionID != first.activeRevisionID else { throw ProbeFailure.check("Changed file did not create revision") }
   await index.shutdown();owned=nil
   let reopened=try SourceIndex(databaseURL:db);owned=reopened
   let after=try await reopened.search("新预算多少钱，谁准备报告？",sourceIDs:ids,accountScopes:scopes)
   guard after.first?.sourceID==first.id,after.first?.revisionID==revised.activeRevisionID,after.first?.text.contains("四万元") == true else { throw ProbeFailure.check("Reopen/current revision mismatch") }
   try await reopened.delete(sourceID:first.id)
   try await reopened.revoke(sourceID:second.id)
   let excluded=try await reopened.search("预算和午餐",sourceIDs:ids,accountScopes:scopes)
   guard !excluded.contains(where:{$0.sourceID==first.id || $0.sourceID==second.id}) else { throw ProbeFailure.check("Deleted/revoked source leaked") }
   let empty=try await reopened.search("预算",sourceIDs:[],accountScopes:scopes)
   guard empty.isEmpty else { throw ProbeFailure.check("Empty scope widened") }
   await reopened.shutdown();owned=nil
   print(String(decoding:try JSONSerialization.data(withJSONObject:["scope":"Production SQLite source index + default verified Google embedding; controlled TXT/MD/native PDF corpus, not RAG answer/UI acceptance","ingested_sources":3,"embedding_space":try JSONSerialization.jsonObject(with:JSONEncoder().encode(hits[0].embeddingSpace)),"original_revision":first.activeRevisionID ?? "","updated_revision":revised.activeRevisionID ?? "","first_scores":hits.map(\.score),"first_top_source_matches":true,"duplicate_revision_retained":true,"saved_snapshot_unchanged_after_file_edit":true,"updated_revision_after_reopen":true,"pdf_page":1,"deleted_and_revoked_excluded":true,"empty_scope_empty":true,"shutdown_returned":true],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
  } catch { await owned?.shutdown(); throw error }
 }
}
