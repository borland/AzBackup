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

do {
    let account = try AZSCloudStorageAccount(fromConnectionString: azureConnectionString)
    let blobClient: AZSCloudBlobClient = account.getBlobClient()
    
//    let cts = AZSContinuationToken()
//    blobClient.listContainersSegmented(with: cts) { (error, segment) in
//        if let err = error {
//            print("failed to list containers \(err)")
//            exit(990)
//        }
//        guard let seg = segment else { return }
//        for x in seg.results {
//            guard let container = x as? AZSCloudBlobContainer else { continue }
//            print(container.name)
//        }
//        exit(0)
//    }
//
    guard let container = blobClient.containerReference(fromName: "my-cool-container") else {
        throw BackupError(message: "can't get container reference")
    }

    container.createContainerIfNotExists { (error, exists) in
        if let err = error {
            print("failed to create container \(err)")
            exit(989)
        }
        print("container exists")
        exit(0)
    }
    
} catch let err {
    print("Can't connect to azure, error \(err)")
    exit(988)
}

// Run GCD main dispatcher, this function never returns, call exit() elsewhere to quit the program or it will hang
dispatchMain()
