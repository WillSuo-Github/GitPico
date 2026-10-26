import Foundation
import Testing
@testable import GitCore

@Test func lfsServerLockRoundTripAndStaleLockProtection() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let script = f.url.appendingPathComponent(".git/lock-server.py"), portFile = f.url.appendingPathComponent(".git/lock-port")
    let source = #"""
import http.server, json, pathlib, sys
from urllib.parse import urlsplit, parse_qs
locks = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, value, status=200):
        data=json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Type','application/vnd.git-lfs+json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        query=parse_qs(urlsplit(self.path).query)
        self.reply({'locks':[item for item in locks if not query.get('id') or item['id'] == query['id'][0]]})
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
        if self.path.endswith('/locks/verify'): self.reply({'ours':locks,'theirs':[]})
        elif self.path.endswith('/unlock'):
            item=locks.pop(0) if locks else None
            self.reply({'lock':item})
        elif self.path.endswith('/clear'):
            locks.clear(); self.reply({})
        else:
            item={'id':'1','path':body['path'],'owner':{'name':'GitPico Fixture'},'locked_at':'2026-10-26T00:00:00Z'}
            locks.append(item); self.reply({'lock':item},201)
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
"""#
    try source.write(to: script, atomically: true, encoding: .utf8)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script.path, portFile.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); defer { if process.isRunning { process.terminate() } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: portFile.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    let port = try String(contentsOf: portFile, encoding: .utf8)
    let endpoint = "http://127.0.0.1:" + port + "/lfs"
    try await f.git(["remote", "add", "origin", f.url.appendingPathComponent(".git/unused-origin.git").path])
    try await f.git(["config", "lfs.url", endpoint])
    let head = try await f.repo.headPosition()
    let lock = try await f.repo.previewLFSLock(.lock("readme.txt"), remote: "origin")
    try await f.repo.runLFSLock(lock)
    let item = try #require(try await f.repo.lfsLocks(remote: "origin").first)
    #expect(item.path == "readme.txt" && item.owner.name == "GitPico Fixture")
    let unlock = try await f.repo.previewLFSLock(.unlock(item, force: false), remote: "origin")
    try await f.repo.runLFSLock(unlock)
    #expect(try await f.repo.lfsLocks(remote: "origin").isEmpty)
    try await f.repo.runLFSLock(try await f.repo.previewLFSLock(.lock("readme.txt"), remote: "origin"))
    let current = try #require(try await f.repo.lfsLocks(remote: "origin").first)
    let stale = try await f.repo.previewLFSLock(.unlock(current, force: true), remote: "origin")
    var request = URLRequest(url: URL(string: endpoint + "/clear")!); request.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: request)
    await #expect(throws: GitFailure.self) { try await f.repo.runLFSLock(stale) }
    #expect(try await f.repo.headPosition() == head)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}
