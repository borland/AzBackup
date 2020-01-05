//
//  Config.swift
//  AzBackup
//
//  Created by Orion Edwards on 4/01/20.
//  Copyright © 2020 orionedwards. All rights reserved.
//

import Foundation

struct ConfigRoot : Decodable {
    /// Backup target. Valid values are "Azure"
    let target: String
    
    /// Path to file containing the azure connection string. Don't check that into source control!
    let connectionStringFile: String?
    
    /// Azure Blob container to store files in
    let blobContainer: String
    
    /// List of things to backup
    let backup: [ConfigBackupEntry]
    
    static func load(filePath: String) throws -> ConfigRoot {
        let url = URL(fileURLWithPath: filePath)
        let json = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConfigRoot.self, from: json)
    }
}

struct ConfigBackupEntry : Decodable {
    /// If true or nil, this entry will be processed. If false will be explicitly skipped
    let enabled: Bool?
    
    /// The local directory
    let dir: String
    
    /// The remote directory
    let target: String
    
    /// File include patterns
    let include: [String]?
    
    /// File exclude patterns
    let exclude: [String]?
}
