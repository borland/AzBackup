//
//  AsyncHelpers.swift
//  AzBackup
//
//  Created by Orion Edwards on 27/12/20.
//  Copyright © 2020 orionedwards. All rights reserved.
//

import Foundation
import MiniRxSwift


extension AZSCloudBlobClient {
    func listContainers() -> Observable<[AZSCloudBlobContainer]> {
        return .create { observer in
            let disposable = BooleanDisposable()
            
            func callback(err: Error?, segment: AZSContainerResultSegment?) {
                if disposable.isDisposed {
                    return // cancelled; abort
                }
                if let e = err {
                    observer.onError(e)
                    return
                }
                guard let seg = segment else { fatalError("listContainersSegmented didn't provide either err nor segment") }
                
                if let results = seg.results as? [AZSCloudBlobContainer] { // we have some results
                    observer.onNext(results)
                    
                    // fetch the next segment if there is one
                    if let nextCt = seg.continuationToken {
                        self.listContainersSegmented(with: nextCt, completionHandler: callback)
                    } else {
                        observer.onCompleted()
                    }
                    
                } else { // nil results indicates no more
                    observer.onCompleted()
                }
            }
            
            self.listContainersSegmented(with: AZSContinuationToken(), completionHandler: callback)
            
            return disposable
        }
    }
}

extension AZSCloudBlobContainer {
    func listBlobs(prefix: String?, batchSize: Int = 1000) -> Observable<[AZSCloudBlockBlob]> {
        return .create { observer in
            let disposable = BooleanDisposable()
            let blobListingDetails: AZSBlobListingDetails = [.metadata, .uncommittedBlobs]
            
            func callback(err: Error?, segment: AZSBlobResultSegment?) {
                if disposable.isDisposed {
                    return // cancelled; abort now
                }
                if let e = err {
                    observer.onError(e)
                    return
                }
                guard let seg = segment else { fatalError("listContainersSegmented didn't provide either err nor segment") }
                
                // because we asked for flat, we just get all the blobs, no directories
                if let results = seg.blobs as? [AZSCloudBlockBlob] { // we have some results
                    observer.onNext(results)
                    
                    // fetch the next segment if there is one
                    if let nextCt = seg.continuationToken {
                        self.listBlobsSegmented(
                            with: nextCt,
                            prefix: prefix,
                            useFlatBlobListing: true,
                            blobListingDetails: blobListingDetails,
                            maxResults: batchSize,
                            accessCondition: nil,
                            requestOptions: nil,
                            operationContext: nil,
                            completionHandler: callback)
                    } else {
                        observer.onCompleted()
                    }
                    
                } else { // nil results indicates no more
                    observer.onCompleted()
                }
            }
            self.listBlobsSegmented(
                with: AZSContinuationToken(),
                prefix: prefix,
                useFlatBlobListing: true,
                blobListingDetails: blobListingDetails,
                maxResults: batchSize,
                accessCondition: nil,
                requestOptions: nil,
                operationContext: nil,
                completionHandler: callback)
            
            return disposable
        }
    }
}

extension AZSCloudBlockBlob {
    func upload(fileUrl: URL) -> Observable<Void> {
        return .create { observer in
            self.uploadFromFile(with: fileUrl) { (err) in
                if let e = err {
                    observer.onError(e)
                } else {
                    observer.onNext(())
                    observer.onCompleted()
                }
            }
            return Disposables.create()
        }
    }
}

extension AZSCloudBlobContainer {
    func createIfNotExists() -> Observable<AZSCloudBlobContainer> {
        return .create { observer in
            self.createContainerIfNotExists { (err, value) in
                if let e = err {
                    observer.onError(e)
                } else {
                    observer.onNext(self)
                    observer.onCompleted()
                }
            }
            return Disposables.create()
        }
    }
}
