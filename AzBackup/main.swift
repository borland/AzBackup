//
//  main.swift
//  AzBackup
//
//  Created by Orion Edwards on 30/12/19.
//  Copyright © 2019 orionedwards. All rights reserved.
//

import Foundation
import Combine

print("Hello, World!")

let connectionStringFile: URL
if CommandLine.arguments.count == 2 {
    connectionStringFile = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    connectionStringFile = dir.appendingPathComponent("azure-connection-string")
}

let azureConnectionString: String
do {
    azureConnectionString = try String(contentsOf: connectionStringFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch let err {
    print("Can't read file, error \(err)")
    exit(987)
}

print("connecting to azure")

struct BackupError : Error {
    let message: String
    
    var localizedDescription: String {
        message
    }
}

var cancellable: Cancellable?

do {
    let account = try AZSCloudStorageAccount(fromConnectionString: azureConnectionString)
    let blobClient: AZSCloudBlobClient = account.getBlobClient()

    // we can't cancel any of this
    cancellable = blobClient
        .listContainers()
        .flatMap { (containers:[AZSCloudBlobContainer]) -> AnyPublisher<AZSCloudBlobContainer, Error> in

            for container in containers {
                print(container.name!)
            }

            guard let container = blobClient.containerReference(fromName: "my-cool-container") else {
                return Fail(error: BackupError(message: "can't get container reference")).eraseToAnyPublisher()
            }
            return container
                .createIfNotExists()
                .map { _ in container }
                .eraseToAnyPublisher()
    }.flatMap { (container) -> Future<Void, Error> in
        print("created container")
        
        
        
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let fooTxt = dir.appendingPathComponent("foo.txt")
        
        //now upload a file
        let blob = container.blockBlobReference(fromName: "foo.txt")!
        return blob.upload(fileUrl: fooTxt)
    }.sink(receiveCompletion: { completion in
        if case .failure(let err) = completion {
            print("Failed with error \(err)")
            exit(999)
        }

        print("all done")
        exit(0)
    }, receiveValue: { (value: Void) in
        print("got value \(value)")
    })


    
} catch let err {
    print("Can't connect to azure, error \(err)")
    exit(988)
}

// Run GCD main dispatcher, this function never returns, call exit() elsewhere to quit the program or it will hang
dispatchMain()
