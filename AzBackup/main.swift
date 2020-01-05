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

let config: ConfigRoot
if CommandLine.arguments.count > 1 {
    let cfg = CommandLine.arguments[1]
    do {
        config = try ConfigRoot.load(filePath: cfg)
    } catch let err {
        print(err.localizedDescription)
        exit(987)
    }
} else {
    print("must pass a path to a valid config file on the command line")
    exit(987)
}

let azureConnectionString: String
do {
    guard let connectionStringFile = config.connectionStringFile else {
        print("connection string file missing")
        exit(987)
    }
    azureConnectionString = try String(contentsOf: URL(fileURLWithPath: connectionStringFile), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch let err {
    print("Can't read file, error \(err)")
    exit(987)
}

if config.backup.isEmpty {
    print("Nothing to back up")
    exit(987)
}

print("connecting to azure")

struct BackupError : Error {
    let message: String
    
    var localizedDescription: String {
        message
    }
}

enum FileOperationType {
    case created, updated, alreadyUpToDate, deleted
}
struct FileOperation {
    let type: FileOperationType
    let file: URL
}

let fsDispatchQueue = DispatchQueue(label: "fsQueue")

class UploadManager {
    typealias QueuedTask = (task: AnyPublisher<Void, Error>, fileOperation: FileOperation)
    
    private let dispatchQueue = DispatchQueue(label: "uploadQueue")

    private var uploadQueue: [QueuedTask] = []
    private var isProcessing = false
    private var currentTask: Cancellable?
    
    let results = PassthroughSubject<FileOperation, Never>()

    func queueUpload(task: AnyPublisher<Void, Error>, fileOperation: FileOperation) {
        dispatchQueue.async {
            self.uploadQueue.append(QueuedTask(task: task, fileOperation: fileOperation))
            if !self.isProcessing {
                self.doProcessing()
            }
        }
    }
    
    private func doProcessing() {
        assert(!uploadQueue.isEmpty) // shouldn't happen
        isProcessing = true
        
        let task = uploadQueue.remove(at: 0)
        self.currentTask = task.task.sink(receiveCompletion: { (signal) in
            self.currentTask = nil
            
            switch signal {
            case .finished:
                self.results.send(FileOperation(type: .created, file: task.fileOperation.file))
                
                self.dispatchQueue.async {
                    if self.uploadQueue.isEmpty {
                        self.isProcessing = false // all done, stop now
                        print("Queue empty")
                    } else {
                        self.doProcessing()
                    }
                }
            case .failure(let err):
                print("Upload failed for \(task.fileOperation.file) - \(err)")
                // carry on with the next one
            }
        }) { () in
            // useless. Progress might go here?
        }
        
    }
}
let uploadManager = UploadManager()
let forever = uploadManager.results.sink(receiveCompletion: { (signal) in
    
}, receiveValue: { op in
    print("\(op.type) \(op.file.relativePath)")
})

let lastModificationDateKey = "lastModificationDate"
let dateFormatter = ISO8601DateFormatter()

func processBackupEntry(_ entry: ConfigBackupEntry, container: AZSCloudBlobContainer, blobs: [AZSCloudBlockBlob]) -> AnyPublisher<FileOperation, Error>
{
    switch entry.enabled {
    case .some(false):
        return Empty<FileOperation, Error>().eraseToAnyPublisher()
    case .none, .some(true):
        break
    }
    
    func queueUpload(fileOperation: FileOperation, remotePath: String, modificationDate: Date) throws {
        guard let blob = container.blockBlobReference(fromName: remotePath) else {
            throw BackupError(message: "Can't create blob reference from \(remotePath)")
        }
        blob.metadata[lastModificationDateKey] = dateFormatter.string(from: modificationDate)
        uploadManager.queueUpload(
            task: blob.upload(fileUrl: fileOperation.file).eraseToAnyPublisher(),
            fileOperation: fileOperation)
    }
    
    return Deferred { () -> PassthroughSubject<FileOperation, Error> in
        let subject = PassthroughSubject<FileOperation, Error>()
        
        // probably some sort of subscriber demand thing is appropriate for Combine
        fsDispatchQueue.async { // do it in the background to prevent the "sending results before subscriber connects" problem
            let dir = URL(fileURLWithPath: entry.dir)
            if let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                
                for case let fileURL as URL in enumerator {
                    do {
                        let fileAttributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                        if fileAttributes.isRegularFile == true {
                            // first work out where it's going to go
                            let remotePath = entry.target + fileURL.relativePath.replacingOccurrences(of: dir.relativePath, with: "")
                            
                            // let's see if it exists in azure
                            let remoteMatch = blobs.first { blob in remotePath == blob.blobName! }
                            
                            if let rm = remoteMatch, let lastModStr = rm.metadata[lastModificationDateKey] as? String {
                                // need to compare strings because the raw contentModificationDate includes milliseconds which aren't roundtripped
                                // via ISO8601DateFormatter with the same precision
                                if lastModStr == dateFormatter.string(from: fileAttributes.contentModificationDate!) {
                                    subject.send(FileOperation(type: .alreadyUpToDate, file: fileURL))
                                } else { // file modification date mismatch. Overwrite remote file
                                    try queueUpload(
                                        fileOperation: FileOperation(type: .updated, file: fileURL),
                                        remotePath: remotePath,
                                        modificationDate: fileAttributes.contentModificationDate!)
                                }
                            } else { // new file
                                try queueUpload(
                                    fileOperation: FileOperation(type: .created, file: fileURL),
                                    remotePath: remotePath,
                                    modificationDate: fileAttributes.contentModificationDate!)
                            }
                        }
                    } catch {
                        subject.send(completion: .failure(error))
                        return
                    }
                }
                subject.send(completion: .finished)
            }
        }
        return subject
    }.eraseToAnyPublisher()
}

var cancellable: Cancellable?

do {
    let account = try AZSCloudStorageAccount(fromConnectionString: azureConnectionString)
    let blobClient: AZSCloudBlobClient = account.getBlobClient()

    // we can't cancel any of this. Ctrl+C to just kill the program
    guard let container = blobClient.containerReference(fromName: config.blobContainer) else {
        throw BackupError(message: "can't get container reference for \(config.blobContainer)")
    }
    cancellable = container
        .createIfNotExists()
        .eraseToAnyPublisher()
        .flatMap { (container) -> AnyPublisher<(container: AZSCloudBlobContainer, blobs: [AZSCloudBlockBlob]), Error> in
            // step 1: list all the files from azure and hold the info in a buffer
            // This is not really optimal as it takes ages and requires heaps of memory but meh, works well enough
            print("LISTING BLOBS")
            return container
                .listBlobs()
                .flatMap { Publishers.Sequence(sequence: $0) }
                .collect()
                .map { blobs in (container: container, blobs: blobs) }
                .eraseToAnyPublisher()
        }
        .flatMap({ (container: AZSCloudBlobContainer, blobs: [AZSCloudBlockBlob]) -> AnyPublisher<FileOperation, Error> in
            print("WALKING LOCAL FILESYSTEM")
            var tasks: [AnyPublisher<FileOperation, Error>] = .init()
            
            for entry in config.backup {
                tasks.append(processBackupEntry(entry, container: container, blobs: blobs))
            }
            return Publishers.Sequence(sequence: tasks).flatMap{ $0 }.eraseToAnyPublisher()
        })
        .sink(receiveCompletion: { signal in }, receiveValue: { fileOperation in
            print("\(fileOperation.file) -> \(String(describing: fileOperation.type))")
        })
    
//
//    cancellable = blobClient
//        .listContainers()
//        .flatMap { (containers:[AZSCloudBlobContainer]) -> AnyPublisher<AZSCloudBlobContainer, Error> in
//
//            for container in containers {
//                print(container.name!)
//            }
//
//
//    }.flatMap { (container) -> AnyPublisher<(container: AZSCloudBlobContainer, blobs: [AZSCloudBlockBlob]), Error> in
//        print("created container")
//
//        return container.listBlobs()
//            .map { (blobs: [AZSCloudBlockBlob]) -> (container: AZSCloudBlobContainer,  blobs: [AZSCloudBlockBlob]) in
//                (container: container, blobs: blobs)
//        }.eraseToAnyPublisher()
//
//    }.flatMap { (tuple:(container: AZSCloudBlobContainer, blobs: [AZSCloudBlockBlob])) -> AnyPublisher<String, Error> in
//        let (container, blobs) = tuple
//
//        for blob in blobs {
//            print(blob.blobName!)
//        }
//
//        return Just("done").setFailureType(to: Error.self).eraseToAnyPublisher()
//    }.sink(
//        receiveCompletion: { _ in }, receiveValue: { _ in })
//
//        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
//        let fooTxt = dir.appendingPathComponent("foo.txt")
//
//        //now upload a file
//        let blob = container.blockBlobReference(fromName: "foo.txt")!
//        return blob.upload(fileUrl: fooTxt)
//    }.sink(receiveCompletion: { completion in
//        if case .failure(let err) = completion {
//            print("Failed with error \(err)")
//            exit(999)
//        }
//
//        print("all done")
//        exit(0)
//    }, receiveValue: { (value: Void) in
//        print("got value \(value)")
//    })


    
} catch let err {
    print("Can't connect to azure, error \(err)")
    exit(988)
}

// Run GCD main dispatcher, this function never returns, call exit() elsewhere to quit the program or it will hang
dispatchMain()
