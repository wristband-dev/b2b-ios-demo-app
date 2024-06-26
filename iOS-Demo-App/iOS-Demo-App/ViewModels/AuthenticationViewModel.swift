import Foundation
import SwiftUI

@MainActor
class AuthenticationViewModel: ObservableObject {
    
    // Authentication view state
    @Published var isLoading = true
    @Published var path = NavigationPath()
    @Published var errorMsg: String?
    
    // Info.plsy
    @Published var appVanityDomain: String?
    @Published var clientId: String?
    
    // Login Browser
    @Published var showAppLoginBrowser = false
    @Published var showTenantLoginBrowser = false
    @Published var showSignUpBrowser = false
    @Published var tenantDomainName: String?
    @Published var tenantId: String?
    
    // Logout Browser
    @Published var showLogOutBrowser = false
    
    // Login
    @Published var codeVerifier: String?
    @Published var codeChallenge: String?
    @Published var state: String?
    @Published var nonce: String?
    
    
    // Response Token
    @Published var tokenResponse: TokenResponse? = nil
    
    var isUserAuthenticated: Bool {
        return tokenResponse != nil ? true : false
    }

    init() {
        getInfoDictValues()
    }
    
    
    func getInfoDictValues() {
        self.appVanityDomain = Bundle.main.infoDictionary?["APPLICATION_VANITY_DOMAIN"] as? String
        self.clientId = Bundle.main.infoDictionary?["CLIENT_ID"] as? String
    }
    
    
    func getStoredToken() async {
        self.tokenResponse = await KeychainService.shared.getToken()
        
        let _ = await getToken()
        
        self.isLoading = false
    }
    
    func getStoredTenantDomainName() async {
        self.tenantDomainName = await KeychainService.shared.getTenantDomainName()  
    }
    
    
    func getToken() async -> String? {
        // if no token return nil and show auth
        guard let tokenResponse else {
            return nil
        }

        // if token is not expired return access token
        guard tokenResponse.isTokenExpired else {
            return tokenResponse.accessToken
        }
            
        // if token expired, attempt to refresh token
        do {
            try await refreshToken(refreshToken: tokenResponse.refreshToken)
            return self.tokenResponse?.accessToken
        // unable to refresh return nil and show auth screen
        } catch {
            self.tokenResponse = nil
            return nil
        }
    }
    
    // WRISTBAND_TOUCHPOINT - get redirect url
    func handleRedirectUri(url: URL) async {
        
        guard url.scheme == "mobiledemoapp" else {
            return
        }

        // get components from url
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        
        // login browser
        if url.host == "login" {
            // get tenant_domain
            if let tenantDomain = components?.queryItems?.first(where: { $0.name == "tenant_domain" })?.value {
                // generate login utilities
                await generatePKCE()
                await generateNonce()
                await generateState()
                
                // get info from login
                self.tenantDomainName = tenantDomain
                KeychainService.shared.saveTenantDomainName(tenantDomainName: tenantDomain)
                
                // clear token response incase the login is redirected from invite
                self.tokenResponse = nil

                // get tenant login
                self.showAppLoginBrowser = false
                self.showTenantLoginBrowser = true
            }
            
            if let loginHint = components?.queryItems?.first(where: { $0.name == "login_hint" })?.value {
                self.tenantId = loginHint
            }
            
        // on login callback or invite user
        } else if url.host == "callback" {
            
            // get code
            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, self.state == components?.queryItems?.first(where: { $0.name == "state" })?.value {
                await createToken(code: code)
            }
            
            // remove path
            self.path.removeLast(self.path.count)
            
        // on logout
        } else if url.host == "logout" {
            // clear cached token
            self.tokenResponse = nil
            
            // clear stored token
            KeychainService.shared.deleteToken()
            KeychainService.shared.deleteTenantDomainName()
            
            // return to main path
            self.path.removeLast(self.path.count)
            
            // close logout browser
            self.showLogOutBrowser = false
        }
        
    }
    
    
    func createToken(code: String) async {
        if let appVanityDomain, let clientId, let codeVerifier {
            
            do {
                // WRISTBAND_TOUCHPOINT - get token
                self.tokenResponse = try await AuthenticationService.shared.getToken(appVanityDomain: appVanityDomain, authCode: code, clientId: clientId, codeVerifier: codeVerifier)

                // create token expiration date
                if let expiresIn = tokenResponse?.expiresIn {
                    self.tokenResponse?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
                }
                
                // save token to keychain
                if let tokenResponse {
                    KeychainService.shared.saveToken(tokenResponse: tokenResponse)
                }
                
                // proceed to content view
                self.showTenantLoginBrowser = false
                
            } catch {
                self.showTenantLoginBrowser = false
                self.errorMsg = "Unable to login, please reach out for support"
                print("Unable to get token: \(error)")
            }
        }
    }
    
    
    func refreshToken(refreshToken: String) async throws{
        if let appVanityDomain, let clientId {
     
            // WRISTBAND_TOUCHPOINT - get token
            self.tokenResponse = try await AuthenticationService.shared.getRefreshToken(appVanityDomain: appVanityDomain, clientId: clientId, refreshToken: refreshToken)
            
            // create token expiration date
            if let expiresIn = tokenResponse?.expiresIn {
                self.tokenResponse?.tokenExpirationDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            }
            
            // save token to keychain
            if let tokenResponse {
                KeychainService.shared.saveToken(tokenResponse: tokenResponse)
            }
           
        }
    }
    
    func generatePKCE() async {
        self.codeVerifier = LoginService.shared.generateCodeVerifier()
        if let codeVerifier {
            self.codeChallenge = LoginService.shared.generateCodeChallenge(from: codeVerifier)
        }
    }
    
    func generateState() async {
        self.state = LoginService.shared.generateRandomString(length: 22)
    }
    
    func generateNonce() async {
        self.nonce = LoginService.shared.generateRandomString(length: 22)
    }
    
    
    func logout() async {
        
        if let appVanityDomain, let clientId, let refreshToken =  tokenResponse?.refreshToken {
            do {
                // WRISTBAND_TOUCHPOINT - revoke token
                try await AuthenticationService.shared.revokeToken(appVanityDomain: appVanityDomain, clientId: clientId, refreshToken: refreshToken)
                
                // clear cookies
                self.showLogOutBrowser = true
    
            } catch {
                print("Unable to revoke token: \(error)")
            }
        }
    }
}
