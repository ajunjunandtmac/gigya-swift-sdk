//
//  ApiManager.swift
//  GigyaSwift
//
//  Created by Shmuel, Sagi on 05/03/2019.
//  Copyright © 2019 Gigya. All rights reserved.
//

import Foundation

class BusinessApiService: NSObject, IOCBusinessApiServiceProtocol {

    var config: GigyaConfig

    let apiService: IOCApiServiceProtocol

    var sessionService: IOCSessionServiceProtocol

    var accountService: IOCAccountServiceProtocol

    var socialProviderFactory: IOCSocialProvidersManagerProtocol

    var providerAdapter: Provider?

    var resolver: BaseResolver?

    required init(config: GigyaConfig, apiService: IOCApiServiceProtocol, sessionService: IOCSessionServiceProtocol,
                  accountService: IOCAccountServiceProtocol, providerFactory: IOCSocialProvidersManagerProtocol) {
        self.config = config
        self.apiService = apiService
        self.sessionService = sessionService
        self.accountService = accountService
        self.socialProviderFactory = providerFactory
    }

    // Send regular request
    func getSDKConfig() {
        let params = ["include": "permissions,ids,appIds"]
        let model = ApiRequestModel(method: GigyaDefinitions.API.getSdkConfig, params: params)

        apiService.send(model: model, responseType: InitSdkResponseModel.self) { [weak self] result in
            switch result {
            case .success(let data):
                self?.config.save(ids: data.ids)
                print(data)
            case .failure(let error):
                print(error)
                break
            }
        }
    }

    // Send regular request
    func send(api: String, params: [String: String] = [:], completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void ) {
        let model = ApiRequestModel(method: api, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }

    // Send request with generic type.
    func send<T: Codable>(dataType: T.Type, api: String, params: [String: String] = [:], completion: @escaping (GigyaApiResult<T>) -> Void ) {
        let model = ApiRequestModel(method: api, params: params)

        apiService.send(model: model, responseType: T.self, completion: completion)
    }

    func getAccount<T: Codable>(dataType: T.Type, completion: @escaping (GigyaApiResult<T>) -> Void) {

        if accountService.isCachedAccount() {
            completion(.success(data: accountService.getAccount()))
        } else {
            let model = ApiRequestModel(method: GigyaDefinitions.API.getAccountInfo)
            
            apiService.send(model: model, responseType: T.self) { [weak accountService] result in
                switch result {
                case .success(let data):
                    accountService?.account = data
                    completion(result)
                case .failure:
                    completion(result)
                }
            }
        }
    }

    func setAccount<T: Codable>(obj: T, completion: @escaping (GigyaApiResult<T>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let diffParams = self?.accountService.setAccount(newAccount: obj)
            let model = ApiRequestModel(method: GigyaDefinitions.API.setAccountInfo, params: diffParams)

            self?.apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
                switch result {
                case .success:
                    self?.accountService.clear()
                    self?.getAccount(dataType: T.self, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func register<T: Codable>(params: [String: Any], dataType: T.Type, completion: @escaping (GigyaApiResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.initRegistration)

        apiService.send(model: model, responseType: [String: AnyCodable].self) { [weak self] (result) in
            switch result {

            case .success(let data):
                let regToken = data["regToken"]?.value ?? ""
                let makeParams: [String: Any] = ["regToken": regToken, "finalizeRegistration": "true"].merging(params) { $1 }

                let model = ApiRequestModel(method: GigyaDefinitions.API.register, params: makeParams)

                self?.apiService.send(model: model, responseType: T.self, completion: completion)

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func login<T: Codable>(dataType: T.Type, loginId: String, password: String, params: [String: Any], completion: @escaping (GigyaLoginResult<T>) -> Void) {
        var mutatedParams = params
        mutatedParams["loginID"] = loginId
        mutatedParams["password"] = password
        
        let model = ApiRequestModel(method: GigyaDefinitions.API.login, params: mutatedParams)

        apiService.send(model: model, responseType: T.self) { [weak self] result in
            switch result {
            case .success(let data):
                self?.accountService.account = data
                completion(.success(data: data))
            case .failure(let error):
                self?.interruptionResolver(error: error, completion: completion)
            }
        }
    }

    func login<T: Codable>(provider: GigyaSocielProviders, viewController: UIViewController,
                           params: [String: Any], dataType: T.Type, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        providerAdapter = socialProviderFactory.getProvider(with: provider, delegate: self)

        providerAdapter?.login(type: T.self, params: params, viewController: viewController, loginMode: "login") { (result) in
            switch result {
            case .success(let data):
                completion(.success(data: data))
            case .failure(let error):
                self.interruptionResolver(error: error, completion: completion)
            }

        }

        providerAdapter?.didFinish = { [weak self] in
            self?.providerAdapter = nil
        }
    }

    func nativeSocialLogin<T: Codable>(params: [String: Any], completion: @escaping (GigyaApiResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.notifySocialLogin, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
            switch result {
            case .success:
                self?.getAccount(dataType: T.self, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func addConnection<T: Codable>(provider: GigyaSocielProviders, viewController: UIViewController, params: [String: Any], dataType: T.Type, completion: @escaping (GigyaApiResult<T>) -> Void) {
        GigyaLogger.log(with: self, message: "[addConnection] - start")

        providerAdapter = socialProviderFactory.getProvider(with: provider, delegate: self)
        providerAdapter?.login(type: T.self, params: params, viewController: viewController, loginMode: "connect") { (res) in
            completion(res)

            GigyaLogger.log(with: self, message: "[addConnection] - finish: \(res)")
        }
        
        providerAdapter?.didFinish = { [weak self] in
            self?.providerAdapter = nil
        }
    }
    
    func removeConnection(providerName: GigyaSocielProviders, completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        let params = ["provider": providerName.rawValue]

        GigyaLogger.log(with: self, message: "[removeConnection]: params: \(params)")

        let model = ApiRequestModel(method: GigyaDefinitions.API.removeConnection, params: params)
        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }
    
    func logout(completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        GigyaLogger.log(with: self, message: "[logout]")

        let model = ApiRequestModel(method: GigyaDefinitions.API.logout, params: [:])
        apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
            switch result {
            case .success(let data):
                completion(.success(data: data))
                self?.sessionService.clear()
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func finalizeRegistration<T: Codable>(regToken: String, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        let params = ["regToken": regToken, "include": "profile,data,emails,subscriptions,preferences", "includeUserInfo": "true"]

        GigyaLogger.log(with: self, message: "[finalizeRegistration] - params: \(params)")

        send(dataType: T.self, api: GigyaDefinitions.API.finalizeRegistration, params: params) { [weak self] result in
            switch result {
            case .success(let data):
                completion(.success(data: data))

                GigyaLogger.log(with: BusinessApiService.self, message: "[finalizeRegistration] - success")

                self?.resolver = nil
            case .failure(let error):
                let loginError = LoginApiError<T>(error: error, interruption: nil)

                GigyaLogger.log(with: BusinessApiService.self, message: "[finalizeRegistration] - failure: \(error)")

                completion(.failure(loginError))
            }
        }
    }

    private func interruptionResolver<T: Codable>(error: NetworkError, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        switch error {
        case .gigyaError(let data):
            // check if interruption supported
            if data.isInterruptionSupported() {
                GigyaLogger.log(with: self, message: "[interruptionResolver] - interruption supported: \(data)")

                // get interruption by error code
                guard let errorCode: Interruption = Interruption(rawValue: data.errorCode) else { return }

                // get all data from request
                let dataResponse = data.toDictionary()

                guard let regToken = dataResponse["regToken"] as? String else {
                    GigyaLogger.log(with: self, message: "[interruptionResolver] - regToken not exists")

                    forwordFailed(error: error, completion: completion)
                    return
                }

                switch errorCode {
                case .pendingRegistration:
                    let loginError = LoginApiError<T>(error: error, interruption: .pendingRegistration(regToken: regToken))
                    completion(.failure(loginError))
                case .pendingVerification: // pending veryfication
                    let loginError = LoginApiError<T>(error: error, interruption: .pendingVerification(regToken: regToken))
                    completion(.failure(loginError))
                case .conflitingAccounts: // conflicting accounts
                    resolver = LinkAccountsResolver(originalError: error, regToken: regToken, businessDelegate: self, completion: completion)
                case .accountLinked:
                    self.finalizeRegistration(regToken: regToken, completion: completion)
                default:
                    break
                }
            } else {
                GigyaLogger.log(with: self, message: "[interruptionResolver] - interruption not supported")

                forwordFailed(error: error, completion: completion)
            }
        default:
            GigyaLogger.log(with: self, message: "[interruptionResolver] - error: \(error)")

            forwordFailed(error: error, completion: completion)
        }
    }

    private func forwordFailed<T: Codable>(error: NetworkError, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        let loginError = LoginApiError<T>(error: error, interruption: nil)
        completion(.failure(loginError))
    }
}
