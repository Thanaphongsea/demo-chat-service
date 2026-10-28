import SwiftUI

struct DateSeparator: View {
  let date: Date

  var body: some View {
    Text(date, format: .dateTime.weekday(.wide).month().day().year())
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .accessibilityAddTraits(.isHeader)
  }
}
