//
//  WebCacheManager.swift
//  DuckDuckGo
//
//  Copyright © 2017 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import WebKit

public protocol WebCacheManagerCookieStore {
    
    func getAllCookies(_ completionHandler: @escaping ([HTTPCookie]) -> Void)
    
    func setCookie(_ cookie: HTTPCookie, completionHandler: (() -> Void)?)

    func delete(_ cookie: HTTPCookie, completionHandler: (() -> Void)?)
    
}

public protocol WebCacheManagerDataStore {
    
    var cookieStore: WebCacheManagerCookieStore? { get }
    
    func removeAllData(completion: @escaping () -> Void)
    
    func removeAllData(forDomain domain: String, recordType: WebCacheManager.RecordType, completion: @escaping () -> Void)
    
}

public class WebCacheManager {

    private struct Constants {
        static let cookieDomain = "duckduckgo.com"
    }
    
    public enum RecordType {
        case cookies
        case allData
        
        public static let allValues: [RecordType] = [.cookies, .allData]
    }
    
    public static var shared = WebCacheManager()
    
    private init() { }

    public func consumeCookies(cookieStorage: CookieStorage = CookieStorage(),
                               httpCookieStore: WebCacheManagerCookieStore? = WKWebsiteDataStore.default().cookieStore,
                               completion: @escaping () -> Void) {
        
        guard let httpCookieStore = httpCookieStore else {
            completion()
            return
        }

        let cookies = cookieStorage.cookies
        
        guard !cookies.isEmpty else {
            completion()
            return
        }
        
        let group = DispatchGroup()
                        
        for cookie in cookies {
            group.enter()
            httpCookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            group.wait()
            
            DispatchQueue.main.async {
                cookieStorage.clear()
                completion()
            }
        }
    }
    
    public func removeCookies(forDomains domains: [String],
                              dataStore: WebCacheManagerDataStore = WKWebsiteDataStore.default(),
                              completion: @escaping () -> Void) {
        
        guard let cookieStore = dataStore.cookieStore else {
            completion()
            return
        }
        
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            cookies.forEach { cookie in
                domains.forEach { domain in

                    if self.isDuckDuckGoOrAllowedDomain(cookie: cookie, domain: domain) {
                        group.enter()
                        cookieStore.delete(cookie) {
                            group.leave()
                        }
                        
                        // don't try to delete the cookie twice as it doesn't always work (esecially on the simulator)
                        return
                    }
                }
            }
            
            DispatchQueue.global(qos: .background).async {
                _ = group.wait(timeout: .now() + 5)
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
        
    }

    /// The Fire Button does not delete the user's DuckDuckGo search settings, which are saved as cookies. Removing these cookies would reset them and have undesired
    ///  consequences, i.e. changing the theme, default language, etc.  These cookies are not stored in a personally identifiable way. For example, the large size setting
    ///  is stored as 's=l.' More info in https://duckduckgo.com/privacy
    private func isDuckDuckGoOrAllowedDomain(cookie: HTTPCookie, domain: String) -> Bool {
        return cookie.domain == domain || (cookie.domain.hasPrefix(".") && domain.hasSuffix(cookie.domain))
    }

    public func clear(dataStore: WebCacheManagerDataStore = WKWebsiteDataStore.default(),
                      appCookieStorage: CookieStorage = CookieStorage(),
                      logins: PreserveLogins = PreserveLogins.shared,
                      completion: @escaping () -> Void) {
        extractAllowedCookies(from: dataStore.cookieStore, cookieStorage: appCookieStorage, logins: logins) {
            self.clearAllData(dataStore: dataStore, completion: completion)
        }
    }
    
    public func clear(domain: String,
                      recordType: RecordType,
                      dataStore: WebCacheManagerDataStore = WKWebsiteDataStore.default(),
                      completion: @escaping () -> Void) {
        dataStore.removeAllData(forDomain: domain.dropPrefix(prefix: "www."),
                                recordType: recordType,
                                completion: completion)
    }

    private func clearAllData(dataStore: WebCacheManagerDataStore, completion: @escaping () -> Void) {
        dataStore.removeAllData(completion: completion)
    }
    
    private func extractAllowedCookies(from cookieStore: WebCacheManagerCookieStore?,
                                       cookieStorage: CookieStorage,
                                       logins: PreserveLogins,
                                       completion: @escaping () -> Void) {
        
        guard let cookieStore = cookieStore else {
            completion()
            return
        }
        
        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                if cookie.domain == Constants.cookieDomain || logins.isAllowed(cookieDomain: cookie.domain) {
                    cookieStorage.setCookie(cookie)
                }
            }
            completion()
        }

    }
    
    /**
     Save all cookies except for those set for the specified domain
     */
    private func extractExcludedDomains(forDomain domain: String,
                                        cookieStore: WebCacheManagerCookieStore?,
                                        cookieStorage: CookieStorage,
                                        logins: PreserveLogins,
                                        completion: @escaping () -> Void) {
        
        guard let cookieStore = cookieStore else {
            completion()
            return
        }
        
        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                if cookie.domain != domain || logins.isAllowed(cookieDomain: cookie.domain) {
                    cookieStorage.setCookie(cookie)
                }
            }
            completion()
        }
    }

}

extension WKHTTPCookieStore: WebCacheManagerCookieStore {
        
}

extension WKWebsiteDataStore: WebCacheManagerDataStore {

    public var cookieStore: WebCacheManagerCookieStore? {
        guard #available(iOS 11, *) else { return nil }
        return self.httpCookieStore
    }

    public func removeAllData(completion: @escaping () -> Void) {
        removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                   modifiedSince: Date.distantPast,
                   completionHandler: completion)
    }
    
    public func removeAllData(forDomain domain: String, recordType: WebCacheManager.RecordType, completion: @escaping () -> Void) {
        let recordTypes: Set<String> = (recordType == .cookies) ? [WKWebsiteDataTypeCookies] : WKWebsiteDataStore.allWebsiteDataTypes()
        fetchDataRecords(ofTypes: recordTypes) { [weak self] records in
            let toRemove = records.filter { record in record.displayName.hasPrefix(domain) }
            
            self?.removeData(ofTypes: recordTypes,
                             for: toRemove,
                             completionHandler: completion)
        }
    }
    
}
