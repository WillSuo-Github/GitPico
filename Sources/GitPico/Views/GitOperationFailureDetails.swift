import SwiftUI

struct GitOperationFailureDetails: View {
    let failure: GitOperationFailure
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("Git operation failed", icon: "exclamationmark.triangle")
            Text(failure.summary).font(.callout).textSelection(.enabled)
                .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            if failure.omittedEarlierOutput {
                Text("Earlier output was omitted. The end of the log is shown below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(failure.details).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Copy Log") { Pico.copy(failure.details) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 640, height: 460)
    }
}
