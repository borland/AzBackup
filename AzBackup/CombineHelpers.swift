//
//  CombineHelpers.swift
//  AzBackup
//
//  Created by Orion Edwards on 2/01/20.
//  Copyright © 2020 orionedwards. All rights reserved.
//

import Foundation
import Combine

extension AZSCloudBlobClient {
    func listContainers() -> Deferred<PassthroughSubject<[AZSCloudBlobContainer], Error>> {
        return Deferred {
            let subject = PassthroughSubject<[AZSCloudBlobContainer], Error>()
            
            func callback(err: Error?, segment: AZSContainerResultSegment?) {
                if let e = err {
                    subject.send(completion: .failure(e))
                    return
                }
                guard let seg = segment else { fatalError("listContainersSegmented didn't provide either err nor segment") }
                
                if let results = seg.results as? [AZSCloudBlobContainer] { // we have some results
                    subject.send(results)
                    
                    // fetch the next segment if there is one
                    if let nextCt = seg.continuationToken {
                        self.listContainersSegmented(with: nextCt, completionHandler: callback)
                    } else {
                        subject.send(completion: .finished)
                    }
                    
                } else { // nil results indicates no more
                    subject.send(completion: .finished)
                }
            }
            
            self.listContainersSegmented(with: AZSContinuationToken(), completionHandler: callback)
            
            return subject
        }
    }
}

extension AZSCloudBlobContainer {
    func listBlobs() -> Deferred<PassthroughSubject<[AZSCloudBlockBlob], Error>> {
        return Deferred {
            let subject = PassthroughSubject<[AZSCloudBlockBlob], Error>()
            
            func callback(err: Error?, segment: AZSBlobResultSegment?) {
                if let e = err {
                    subject.send(completion: .failure(e))
                    return
                }
                guard let seg = segment else { fatalError("listContainersSegmented didn't provide either err nor segment") }
                
                if let results = seg.results as? [AZSCloudBlockBlob] { // we have some results
                    subject.send(results)
                    
                    // fetch the next segment if there is one
                    if let nextCt = seg.continuationToken {
                        self.listB(with: nextCt, completionHandler: callback)
                    } else {
                        subject.send(completion: .finished)
                    }
                    
                } else { // nil results indicates no more
                    subject.send(completion: .finished)
                }
            }
            self.listBlobsSegmented(
                with: AZSContinuationToken(),
                prefix: nil,
                useFlatBlobListing: true,
                blobListingDetails: nil,
                maxResults: 1000,
                accessCondition: <#T##AZSAccessCondition!#>, requestOptions: <#T##AZSBlobRequestOptions!#>, operationContext: <#T##AZSOperationContext!#>, completionHandler: <#T##((Error?, AZSBlobResultSegment?) -> Void)!##((Error?, AZSBlobResultSegment?) -> Void)!##(Error?, AZSBlobResultSegment?) -> Void#>)
            
            self.listContainersSegmented(with: AZSContinuationToken(), completionHandler: callback)
            
            return subject
        }
    }
}


extension AZSCloudBlockBlob {
    func upload(fileUrl: URL) -> Future<Void, Error> {
        return Future<Void, Error> { resolve in
            self.uploadFromFile(with: fileUrl) { (err) in
                if let e = err {
                    resolve(.failure(e))
                } else {
                    resolve(.success(()))
                }
            }
        }
    }
}

extension AZSCloudBlobContainer {
    func createIfNotExists() -> Future<Bool, Error> {
        return Future<Bool, Error> { resolve in
            self.createContainerIfNotExists { (err, value) in
                if let e = err {
                    resolve(.failure(e))
                } else {
                    resolve(.success(value))
                }
            }
        }
    }
}
