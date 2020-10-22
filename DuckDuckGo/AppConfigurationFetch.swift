//
//  AppConfigurationFetch.swift
//  DuckDuckGo
//
//  Copyright © 2018 DuckDuckGo. All rights reserved.
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

import Foundation
import BackgroundTasks
import Core
import os.log

public typealias AppConfigurationCompletion = (Bool) -> Void

protocol AppConfigurationFetchStatistics {
    var foregroundStartCount: Int { get set }
    var foregroundNoDataCount: Int { get set }
    var foregroundNewDataCount: Int { get set }
    
    var backgroundStartCount: Int { get set }
    var backgroundNoDataCount: Int { get set }
    var backgroundNewDataCount: Int { get set }

    var backgroundTaskExpirationCount: Int { get set }

    var downloadedHTTPSBloomFilterSpecCount: Int { get set }
    var downloadedHTTPSBloomFilterCount: Int { get set }
    var downloadedHTTPSExcludedDomainsCount: Int { get set }
    var downloadedSurrogatesCount: Int { get set }
    var downloadedTrackerDataSetCount: Int { get set }
    var downloadedTemporaryUnprotectedSitesCount: Int { get set }
}

class AppConfigurationFetch {
    
    private struct Constants {
        static let backgroundTaskName = "Fetch Configuration Task"
        static let backgroundProcessingTaskIdentifier = "com.duckduckgo.app.configurationRefresh"
        static let minimumConfigurationRefreshInterval: TimeInterval = 60 * 60 * 12
    }
    
    private struct Keys {
        static let bgFetchType = "bgft"
        static let bgFetchTypeBackgroundTasks = "bgbt"
        static let bgFetchTypeLegacy = "bgl"
        static let bgFetchTaskExpiration = "bgte"
        static let bgFetchStart = "bgfs"
        static let bgFetchNoData = "bgnd"
        static let bgFetchWithData = "bgwd"
        static let fgFetchStart = "fgfs"
        static let fgFetchNoData = "fgnd"
        static let fgFetchWithData = "fgwd"

        static let fetchHTTPSBloomFilterSpec = "d1"
        static let fetchHTTPSBloomFilter = "d2"
        static let fetchHTTPSExcludedDomainsCount = "d3"
        static let fetchSurrogatesCount = "d4"
        static let fetchTrackerDataSetCount = "d5"
        static let fetchTemporaryUnprotectedSitesCount = "d6"
    }
    
    private static let fetchQueue = DispatchQueue(label: "Config Fetch queue", qos: .utility)

    @UserDefaultsWrapper(key: .lastConfigurationRefreshDate, defaultValue: .distantPast)
    private var lastConfigurationRefreshDate: Date

    var shouldRefresh: Bool {
        return Date().timeIntervalSince(lastConfigurationRefreshDate) > Constants.minimumConfigurationRefreshInterval
    }
    
    func start(isBackgroundFetch: Bool = false,
               completion: AppConfigurationCompletion?) {
        guard shouldRefresh else {
            // Statistics are not sent after a successful background refresh in order to reduce the time spent in the background, so they are checked
            // here in case a background refresh has happened recently.
            Self.fetchQueue.async {
                self.sendStatistics {
                    completion?(false)
                }
            }

            return
        }

        type(of: self).fetchQueue.async {
            let taskID = UIApplication.shared.beginBackgroundTask(withName: Constants.backgroundTaskName)
            let newData = self.fetchConfigurationFiles(isBackground: isBackgroundFetch)

            if !isBackgroundFetch {
                type(of: self).fetchQueue.async {
                    self.sendStatistics {
                        UIApplication.shared.endBackgroundTask(taskID)
                    }
                }
            } else {
                UIApplication.shared.endBackgroundTask(taskID)
            }

            completion?(newData)
        }
    }

    @available(iOS 13.0, *)
    static func registerBackgroundRefreshTaskHandler() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConfigurationFetch.Constants.backgroundProcessingTaskIdentifier,
            using: fetchQueue) { (task) in

            task.expirationHandler = {
                var store: AppConfigurationFetchStatistics = AppUserDefaults()
                store.backgroundTaskExpirationCount += 1

                scheduleBackgroundRefreshTask()
            }

            AppConfigurationFetch().fetchConfigurationFiles(isBackground: true)
            scheduleBackgroundRefreshTask()

            task.setTaskCompleted(success: true)
        }
    }

    @available(iOS 13.0, *)
    static func scheduleBackgroundRefreshTask() {
        let task = BGProcessingTaskRequest(identifier: AppConfigurationFetch.Constants.backgroundProcessingTaskIdentifier)
        task.requiresNetworkConnectivity = true
        task.earliestBeginDate = Date(timeIntervalSinceNow: Constants.minimumConfigurationRefreshInterval)

        // Background tasks can be debugged by breaking on the `submit` call, stepping over, then running the following LLDB command, before resuming:
        //
        // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.duckduckgo.app.configurationRefresh"]
        //
        // Task expiration can be simulated similarly:
        //
        // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.duckduckgo.app.configurationRefresh"]

        do {
            try BGTaskScheduler.shared.submit(task)
        } catch {
            #if !targetEnvironment(simulator)
            Pixel.fire(pixel: .backgroundTaskSubmissionFailed, error: error)
            #endif
        }
    }

    @discardableResult
    private func fetchConfigurationFiles(isBackground: Bool) -> Bool {
        self.markFetchStarted(isBackground: isBackground)

        var newData = false
        let semaphore = DispatchSemaphore(value: 0)

        AppDependencyProvider.shared.storageCache.update(progress: updateFetchProgress) { newCache in
            newData = newData || (newCache != nil)
            semaphore.signal()
        }

        semaphore.wait()

        self.markFetchCompleted(isBackground: isBackground, hasNewData: newData)
        return newData
    }
    
    private func markFetchStarted(isBackground: Bool) {
        var store: AppConfigurationFetchStatistics = AppUserDefaults()
        
        if isBackground {
            store.backgroundStartCount += 1
        } else {
            store.foregroundStartCount += 1
        }
    }

    private func updateFetchProgress(configuration: ContentBlockerRequest.Configuration) {
        var store: AppConfigurationFetchStatistics = AppUserDefaults()

        switch configuration {
        case .httpsBloomFilter: store.downloadedHTTPSBloomFilterCount += 1
        case .httpsBloomFilterSpec: store.downloadedHTTPSBloomFilterSpecCount += 1
        case .httpsExcludedDomains: store.downloadedHTTPSExcludedDomainsCount += 1
        case .surrogates: store.downloadedSurrogatesCount += 1
        case .temporaryUnprotectedSites: store.downloadedTemporaryUnprotectedSitesCount += 1
        case .trackerDataSet: store.downloadedTrackerDataSetCount += 1
        }
    }
    
    private func markFetchCompleted(isBackground: Bool, hasNewData: Bool) {
        var store: AppConfigurationFetchStatistics = AppUserDefaults()
        
        if isBackground {
            if hasNewData {
                store.backgroundNewDataCount += 1
            } else {
                store.backgroundNoDataCount += 1
            }
        } else {
            if hasNewData {
                store.foregroundNewDataCount += 1
            } else {
                store.foregroundNoDataCount += 1
            }
        }

        lastConfigurationRefreshDate = Date()
    }
    
    private func sendStatistics(completion: () -> Void ) {
        let store: AppConfigurationFetchStatistics = AppUserDefaults()
        guard store.foregroundStartCount > 0 || store.backgroundStartCount > 0 else {
            completion()
            return
        }

        let backgroundFetchType: String

        if #available(iOS 13.0, *) {
            backgroundFetchType = Keys.bgFetchTypeBackgroundTasks
        } else {
            backgroundFetchType = Keys.bgFetchTypeLegacy
        }
        
        let parameters = [Keys.bgFetchStart: String(store.backgroundStartCount),
                          Keys.bgFetchNoData: String(store.backgroundNoDataCount),
                          Keys.bgFetchWithData: String(store.backgroundNewDataCount),
                          Keys.fgFetchStart: String(store.foregroundStartCount),
                          Keys.fgFetchNoData: String(store.foregroundNoDataCount),
                          Keys.fgFetchWithData: String(store.foregroundNewDataCount),
                          Keys.bgFetchType: backgroundFetchType,
                          Keys.bgFetchTaskExpiration: String(store.backgroundTaskExpirationCount),
                          Keys.fetchHTTPSBloomFilterSpec: String(store.downloadedHTTPSBloomFilterSpecCount),
                          Keys.fetchHTTPSBloomFilter: String(store.downloadedHTTPSBloomFilterCount),
                          Keys.fetchHTTPSExcludedDomainsCount: String(store.downloadedHTTPSExcludedDomainsCount),
                          Keys.fetchSurrogatesCount: String(store.downloadedSurrogatesCount),
                          Keys.fetchTrackerDataSetCount: String(store.downloadedTrackerDataSetCount),
                          Keys.fetchTemporaryUnprotectedSitesCount: String(store.downloadedTemporaryUnprotectedSitesCount)]
        
        let semaphore = DispatchSemaphore(value: 0)
        
        Pixel.fire(pixel: .configurationFetchInfo, withAdditionalParameters: parameters) { error in
            guard error == nil else {
                semaphore.signal()
                return
            }
                
            self.resetStatistics()
            semaphore.signal()
        }
        
        semaphore.wait()
        completion()
    }
    
    private func resetStatistics() {
        var store: AppConfigurationFetchStatistics = AppUserDefaults()
        
        store.backgroundStartCount = 0
        store.backgroundNoDataCount = 0
        store.backgroundNewDataCount = 0
        store.foregroundStartCount = 0
        store.foregroundNoDataCount = 0
        store.foregroundNewDataCount = 0
        store.backgroundTaskExpirationCount = 0
        store.downloadedHTTPSBloomFilterCount = 0
        store.downloadedHTTPSBloomFilterSpecCount = 0
        store.downloadedHTTPSExcludedDomainsCount = 0
        store.downloadedSurrogatesCount = 0
        store.downloadedTemporaryUnprotectedSitesCount = 0
        store.downloadedTrackerDataSetCount = 0
    }
}
