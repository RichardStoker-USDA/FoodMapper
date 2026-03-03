import SwiftUI

/// Row for selecting which column to match
struct ColumnPickerRow: View {
    let columns: [String]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Match Column")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Column", selection: $selection) {
                Text("Select column...").tag(nil as String?)
                ForEach(columns, id: \.self) { column in
                    Text(column).tag(column as String?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .flexiblePickerSizing()
            .help("Select the column containing food descriptions to match")
        }
    }
}

#Preview("Column Picker - Selected - Light") {
    ColumnPickerRow(
        columns: PreviewHelpers.sampleColumns,
        selection: .constant("food_description")
    )
    .padding()
    .frame(width: 220)
}

#Preview("Column Picker - Dark") {
    ColumnPickerRow(
        columns: PreviewHelpers.sampleColumns,
        selection: .constant("food_description")
    )
    .padding()
    .frame(width: 220)
    .preferredColorScheme(.dark)
}

#Preview("Column Picker - No Selection") {
    ColumnPickerRow(
        columns: PreviewHelpers.sampleColumns,
        selection: .constant(nil)
    )
    .padding()
    .frame(width: 220)
}
