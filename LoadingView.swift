import SwiftUI

struct LoadingView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var networkMonitor: NetworkMonitor
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.8),
                    Color.purple.opacity(0.6)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                Text("Speedy")
                    .font(.system(size: 100, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(gradient: Gradient(colors: [Color.white, Color.blue.opacity(0.6)]), startPoint: .top, endPoint: .bottom))
                    .shadow(radius: 10)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                    .padding(.top, 20)
            }
        }
    }
}

struct LoadingView_Previews: PreviewProvider {
    static var previews: some View {
        LoadingView()
            .environmentObject(LocationManager())
            .environmentObject(NetworkMonitor())
    }
}
