import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("Top Scores")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Your personalized TV guide for football matches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Coming soon")
                        .font(.headline)
                    Text("• Developer bio")
                    Text("• Contact details")
                    Text("• Version notes")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("About")
            .toolbarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    AboutView()
}
