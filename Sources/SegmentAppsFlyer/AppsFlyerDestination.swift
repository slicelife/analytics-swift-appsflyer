//
//  AppsFlyerDestination.swift
//
//  Created by Alan Charles on 6/22/21.
//

// MIT License
//
// Copyright (c) 2021 Segment
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// *** To Implement Deep Linking functionality reference: https://support.appsflyer.com/hc/en-us/articles/208874366 ****

import Foundation
import Segment
import AppsFlyerLib

@objc(SEGAppsFlyerDestination)
public class ObjCSegmentAppsFlyer: NSObject, ObjCPlugin, ObjCPluginShim {
    public func instance() -> EventPlugin { return AppsFlyerDestination() }
}

public class AppsFlyerDestination: UIResponder, DestinationPlugin  {

    public typealias AdditionalConfigurationHandler = (AppsFlyerLib) -> Void

    public let timeline = Timeline()
    public let type = PluginType.destination
    public let key = "AppsFlyer"
    
    public weak var analytics: Analytics?

    fileprivate var settings: AppsFlyerSettings? = nil

    private weak var segDelegate: AppsFlyerLibDelegate?
    private weak var segDLDelegate: DeepLinkDelegate?
    private let additionalConfigurationHandler: AdditionalConfigurationHandler?

    // MARK: - Initialization

    /// Creates and returns an AppsFlyer destination plugin for the Segment SDK
    ///
    /// See ``AppsFlyerDestination`` for more information
    ///
    /// - Parameters:
    ///   - segDelegate: When provided, this delegate will get called back for all AppsFlyerDelegate methods - ``onConversionDataSuccess(_:)``, ``onConversionDataFail(_:)``, ``onAppOpenAttribution(_:)``, ``onAppOpenAttributionFailure(_:)``
    ///   - segDLDelegate: When provided, this delegate will get called back for all DeepLinkDelegate routines, or just ``didResolveDeeplink``
    ///   - additionalConfigurationHandler: When provided, this handler will get called after AppsFlyerLib gets configured
    public init(segDelegate: AppsFlyerLibDelegate? = nil,
                segDLDelegate: DeepLinkDelegate? = nil,
                additionalConfigurationHandler: AdditionalConfigurationHandler? = nil) {
        self.segDelegate = segDelegate
        self.segDLDelegate = segDLDelegate
        self.additionalConfigurationHandler = additionalConfigurationHandler
    }

    // MARK: - Plugin
    public func update(settings: Settings, type: UpdateType) {
        // we've already set up this singleton SDK, can't do it again, so skip.
        guard type == .initial else { return }

        guard let settings: AppsFlyerSettings = settings.integrationSettings(forPlugin: self) else { return }
        self.settings = settings
        let appsFlyerLib = AppsFlyerLib.shared()

        appsFlyerLib.appsFlyerDevKey = settings.appsFlyerDevKey
        appsFlyerLib.appleAppID = settings.appleAppID

        appsFlyerLib.deepLinkDelegate = self

        if settings.trackAttributionData {
            appsFlyerLib.delegate = self
        }

        additionalConfigurationHandler?(appsFlyerLib)
    }
    
    public func identify(event: IdentifyEvent) -> IdentifyEvent? {
        if let userId = event.userId, userId.count > 0 {
            AppsFlyerLib.shared().customerUserID = userId
        }
        
        if let traits = event.traits?.dictionaryValue {
            var aFTraits: [AnyHashable: Any] = [:]
            
            aFTraits["email"] = traits["email"] as? String
            aFTraits["firstName"] = traits["firstName"] as? String
            aFTraits["lastName"] = traits["lastName"] as? String

            if let currencyCode = traits["currencyCode"] as? String {
                AppsFlyerLib.shared().currencyCode = currencyCode
            }
            
            AppsFlyerLib.shared().customData = aFTraits
        }
        
        return event
    }
    
    public func track(event: TrackEvent) -> TrackEvent? {
        
        var properties = event.properties?.dictionaryValue

        if let revenue = extractRevenue(from: properties) {
            properties?["af_revenue"] = revenue
            properties?["af_currency"] = extractCurrency(from: properties)

            properties?.removeValue(forKey: "revenue")
            properties?.removeValue(forKey: "currency")
        }

        AppsFlyerLib.shared().logEvent(event.event, withValues: properties)

        return event
    }
}

extension AppsFlyerDestination: RemoteNotifications, iOSLifecycle {
    public func applicationDidBecomeActive(application: UIApplication?) {
        AppsFlyerLib.shared().start()
    }
    
    public func openURL(_ url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) {
        AppsFlyerLib.shared().handleOpen(url, options: options)
    }
    
    public func receivedRemoteNotification(userInfo: [AnyHashable: Any]) {
        AppsFlyerLib.shared().handlePushNotification(userInfo)
    }
}

//MARK: - UserActivities Protocol

extension AppsFlyerDestination: UserActivities {
    public func continueUserActivity(_ activity: NSUserActivity) {
        AppsFlyerLib.shared().continue(activity, restorationHandler: nil)
    }
}


//MARK: - Support methods
// matches existing AppsFlyer Destination to set revenue and currency as reserved properties
// https://github.com/AppsFlyerSDK/segment-appsflyer-ios/blob/master/segment-appsflyer-ios/Classes/SEGAppsFlyerIntegration.m#L148
extension AppsFlyerDestination {

    internal func extractRevenue(from properties: [String: Any]?) -> Double? {
        guard let revenue = properties?["revenue"] else { return nil }
        if let revenue = revenue as? Double {
            return revenue
        }
        if let revenue = revenue as? String {
            return Double(revenue)
        }
        return nil
    }
    
    internal func extractCurrency(from properties: [String: Any]?) -> String {
        (properties?["currency"] as? String) ?? "USD"
    }
}

// MARK: - AppsFlyer Lib Delegate conformance

extension AppsFlyerDestination: AppsFlyerLibDelegate {
    public func onConversionDataSuccess(_ conversionInfo: [AnyHashable : Any]) {
        guard let firstLaunchFlag = conversionInfo["is_first_launch"] as? Int, firstLaunchFlag == 1 else { return }
        guard let status = conversionInfo["af_status"] as? String else { return }

        segDelegate?.onConversionDataSuccess(conversionInfo)

        if status == "Non-organic" {
            if let mediaSource = conversionInfo["media_source"] , let campaign = conversionInfo["campaign"], let adgroup = conversionInfo["adgroup"]{

                let campaign: [String: Any] = [
                    "source": mediaSource,
                    "name": campaign,
                    "ad_group": adgroup
                ]
                let campaignStr = (campaign.compactMap({ (key, value) -> String in
                    return "\(key)=\(value)"
                }) as Array).joined(separator: ";")
                let properties: [String: Codable] = [
                    "provider": "AppsFlyer",
                    "campaign": campaignStr
                ]
                analytics?.track(name: "Install Attributed", properties: properties)
            }
        } else {
            analytics?.track(name: "Organic Install")
        }
    }
    
    public func onConversionDataFail(_ error: Error) {
        segDelegate?.onConversionDataFail(error)
    }
    
    public func onAppOpenAttribution(_ attributionData: [AnyHashable: Any]) {
        segDelegate?.onAppOpenAttribution?(attributionData)
        if let media_source = attributionData["media_source"] , let campaign = attributionData["campaign"],
           let referrer  = attributionData["http_referrer"] {
            
            let campaign: [String: Any] = [
                "source": media_source,
                "name": campaign,
                "url": referrer
            ]
            let campaignStr = (campaign.compactMap({ (key, value) -> String in
                return "\(key)=\(value)"
            }) as Array).joined(separator: ";")
            let properties: [String: Codable] = [
                "provider": "AppsFlyer",
                "campaign": campaignStr
            ]
            
            analytics?.track(name: "Deep Link Opened", properties: properties)
        }
    }

    public func onAppOpenAttributionFailure(_ error: Error) {
        segDelegate?.onAppOpenAttributionFailure?(error)
    }
}

extension AppsFlyerDestination: VersionedPlugin {
    public static func version() -> String {
        return __destination_version
    }
}

//MARK: - AppsFlyer DeepLink Delegate conformance

extension AppsFlyerDestination: DeepLinkDelegate, UIApplicationDelegate {
    
    public func didResolveDeepLink(_ result: DeepLinkResult) {
        segDLDelegate?.didResolveDeepLink?(result)
        switch result.status {
        case .notFound:
            return
        case .failure:
            return
        case .found:
            return
        }
        
        guard let deepLinkObj: DeepLink = result.deepLink else { return }

        if (deepLinkObj.isDeferred == true) {
            
            let campaign: [String: Any] = [
                "source": deepLinkObj.mediaSource ?? "",
                "name": deepLinkObj.campaign ?? "",
                "product": deepLinkObj.deeplinkValue ?? ""
            ]
            let campaignStr = (campaign.compactMap({ (key, value) -> String in
                return "\(key)=\(value)"
            }) as Array).joined(separator: ";")
            let properties: [String: Codable] = [
                "provider": "AppsFlyer",
                "campaign": campaignStr
            ]
            
            analytics?.track(name: "Deferred Deep Link", properties: properties)
            
        } else {
            
            let campaign: [String: Any] = [
                "source": deepLinkObj.mediaSource ?? "",
                "name": deepLinkObj.campaign ?? "",
                "product": deepLinkObj.deeplinkValue ?? ""
            ]
            let campaignStr = (campaign.compactMap({ (key, value) -> String in
                return "\(key)=\(value)"
            }) as Array).joined(separator: ";")
            let properties: [String: Codable] = [
                "provider": "AppsFlyer",
                "campaign": campaignStr
            ]
            
            analytics?.track(name: "Direct Deep Link", properties: properties)
        }
    }
}

private struct AppsFlyerSettings: Codable {
    let appsFlyerDevKey: String
    let appleAppID: String
    let trackAttributionData: Bool?
}
