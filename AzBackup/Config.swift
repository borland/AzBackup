//
//  Config.swift
//  AzBackup
//
//  Created by Orion Edwards on 4/01/20.
//  Copyright © 2020 orionedwards. All rights reserved.
//

import Foundation


//{
//    "target": "Azure",
//    "connectionStringFile": "/Users/orione/Dev/AzBackup/azure-connection-string",
//    "blobContainer": "my-test-container",
//    "backup": [
//        {
//            "dir": "/Users/orione/Downloads/azure-storage-ios-0.2.6",
//            "include": ["*"],
//            "exclude": ["Lib/Azure Storage Client Library/BreakingChanges.txt"]
//        },
//        {
//            "dir": "/Users/orione/Documents",
//            "include": ["*"],
//            "exclude": [
//                "*.p8",
//                "*.pptx"
//            ]
//        }
//    ]
//}

struct ConfigRoot : Decodable {
    let target: String
    let connectionStringFile: String?
    let blobContainer: String
    let backup: [ConfigBackupEntry]
    
    static func load(filePath: String) throws -> ConfigRoot {
        let url = URL(fileURLWithPath: filePath)
        let json = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConfigRoot.self, from: json)
    }
}

struct ConfigBackupEntry : Decodable {
    let enabled: Bool?
    let dir: String
    let include: [String]?
    let exclude: [String]?
}
