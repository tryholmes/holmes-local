import Foundation

// MARK: - Clerk Configuration
// Fill in your Clerk app details from https://dashboard.clerk.com
// Frontend API URL format: https://<your-instance>.clerk.accounts.dev
// OR your custom domain if configured

enum ClerkConfig {
    /// Your Clerk Publishable Key (starts with pk_test_ or pk_live_)
    static let publishableKey = "pk_test_dGVuZGVyLXNxdWlkLTYyLmNsZXJrLmFjY291bnRzLmRldiQ"

    /// Your Clerk Frontend API URL (from Clerk Dashboard → API Keys)
    static let frontendAPIURL = "https://tender-squid-62.clerk.accounts.dev"

    /// Keychain service identifier
    static let keychainService = "com.grain.holmes.clerk"

    /// Keychain account for session token
    static let sessionTokenAccount = "clerk_session_token"

    /// Keychain account for user email
    static let userEmailAccount = "clerk_user_email"
}
