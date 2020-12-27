//
//  main.swift
//  AzBackup
//
//  Created by Orion Edwards on 30/12/19.
//  Copyright © 2019 orionedwards. All rights reserved.
//

import Foundation
import RxSwift

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
    let concurrentUploads = 3
    
    typealias QueuedTask = (task: Observable<Void>, fileOperation: FileOperation)
    
    private let dispatchQueue = DispatchQueue(label: "uploadQueue")

    private var uploadQueue: [QueuedTask] = []
    private var currentTasks: [Int:Disposable] = [:]
    private var lastTaskId = 0 // each task needs some way to remove it from the dict when it's done
    
    let results = PublishSubject<FileOperation>()

    func queueUpload(task: Observable<Void>, fileOperation: FileOperation) {
        dispatchQueue.async {
            self.uploadQueue.append(QueuedTask(task: task, fileOperation: fileOperation))
            self.doProcessing()
        }
    }
    
    private func doProcessing() {
        dispatchPrecondition(condition: .onQueue(self.dispatchQueue))
        
        // the worst thing that happens if we call doProcessing excessively is that
        // this loop runs zero times
        while uploadQueue.count > 0 && currentTasks.count < concurrentUploads {
            let task = uploadQueue.remove(at: 0)
            
            lastTaskId += 1
            let taskId = lastTaskId
            
//            print("starting \(task.fileOperation.type) for \(task.fileOperation.file.relativePath)")
            let cancellable = task.task.subscribe(
                onError: { err in
                    print("Upload failed for \(task.fileOperation.file) - \(err)")
                    // carry on with the next one
                },
                onCompleted: {
                    self.currentTasks.removeValue(forKey: taskId)
                
                    self.results.onNext(task.fileOperation)
                    
                    self.dispatchQueue.async {
                        if self.uploadQueue.isEmpty {
                            print("Queue empty")
                        } else {
                            self.doProcessing()
                        }
                    }
                })
            
            // we need to stash the cancellable somewhere as Combine kills it if it goes out of scope
            currentTasks[taskId] = cancellable
        }
            
    }
}
let uploadManager = UploadManager()
let forever = uploadManager.results.subscribe(onNext: { op in
    print("\(op.type) \(op.file.relativePath)")
})

let lastModificationDateKey = "lastModificationDate"
let dateFormatter = ISO8601DateFormatter()

func isIncluded(path: String, includePredicates: [NSPredicate]?, excludePredicates: [NSPredicate]?) -> Bool {
    var included = false
    if let ip = includePredicates {
        included = ip.contains { pred in pred.evaluate(with: path) }
    } else {
        included = true
    }
    
    var excluded = false
    if let ep = excludePredicates {
        excluded = ep.contains { pred in pred.evaluate(with: path) }
    }
    
    return included && !excluded // exclude wins
}

func processBackupEntry(_ entry: ConfigBackupEntry, container: AZSCloudBlobContainer, blobs: [String:AZSCloudBlockBlob]) -> Observable<FileOperation>
{    
    func queueUpload(fileOperation: FileOperation, remotePath: String, modificationDate: Date) throws {
        guard let blob = container.blockBlobReference(fromName: remotePath) else {
            throw BackupError(message: "Can't create blob reference from \(remotePath)")
        }
        blob.metadata[lastModificationDateKey] = dateFormatter.string(from: modificationDate)
        uploadManager.queueUpload(
            task: blob.upload(fileUrl: fileOperation.file),
            fileOperation: fileOperation)
    }
    
    // convert include patterns to NSPredicate. May not be the ideal most efficient way to do wildcard matching, but it's very easy :-)
    let includePredicates: [NSPredicate]?
    if let ip = entry.include {
        includePredicates = ip.map{ NSPredicate(format: "self LIKE %@", $0) }
    } else {
        includePredicates = nil
    }
    
    let excludePredicates: [NSPredicate]?
    if let ep = entry.exclude {
        excludePredicates = ep.map{ NSPredicate(format: "self LIKE %@", $0) }
    } else {
        excludePredicates = nil
    }
    
    // actual work happens here
    return Observable.create { (observer: AnyObserver<FileOperation>) -> Disposable in
        // probably some sort of subscriber demand thing is appropriate for Combine
        let disposable = BooleanDisposable()
        fsDispatchQueue.async { // do it in the background to prevent the "sending results before subscriber connects" problem
            print("Scanning filesystem under \(entry.dir)")
            
            let dir = URL(fileURLWithPath: entry.dir)
            if let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            {
                for case let fileURL as URL in enumerator {
                    if disposable.isDisposed {
                        return // give up when cancelled
                    }
                    
                    let relativePath = fileURL.relativePath.replacingOccurrences(of: dir.relativePath, with: "")
                    if !isIncluded(path: relativePath, includePredicates: includePredicates, excludePredicates: excludePredicates) {
                        //print("skipping excluded file \(relativePath)")
                        continue
                    }
                    
                    do {
                        let fileAttributes = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                        if fileAttributes.isRegularFile == true {
                            // first work out where it's going to go under the remote target dir
                            let remotePath = entry.target + relativePath
                            
                            // let's see if it exists in azure
                            let remoteMatch = blobs[remotePath]
                            
                            if let rm = remoteMatch, let lastModStr = rm.metadata[lastModificationDateKey] as? String {
                                // need to compare strings because the raw contentModificationDate includes milliseconds which aren't roundtripped
                                // via ISO8601DateFormatter with the same precision
                                if lastModStr == dateFormatter.string(from: fileAttributes.contentModificationDate!) {
                                    observer.onNext(FileOperation(type: .alreadyUpToDate, file: fileURL))
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
                        observer.onError(error)
                        return
                    }
                }
                observer.onCompleted()
            }
        }
        return disposable
    }
}

var disposable: Disposable?

do {
    let account = try AZSCloudStorageAccount(fromConnectionString: azureConnectionString)
    let blobClient: AZSCloudBlobClient = account.getBlobClient()
    
    // we can't cancel any of this. Ctrl+C to just kill the program
    guard let container = blobClient.containerReference(fromName: config.blobContainer) else {
        throw BackupError(message: "can't get container reference for \(config.blobContainer)")
    }
    disposable = container
        .createIfNotExists()
        .flatMap { (container) -> Observable<(container: AZSCloudBlobContainer, entry: ConfigBackupEntry)> in
            Observable.from(config.backup)
                .filter { entry in entry.enabled != false }
                .map { entry in (container: container, entry: entry) }
    }
    .flatMap { (container, entry) -> Observable<(container: AZSCloudBlobContainer, entry: ConfigBackupEntry, blobs: [String:AZSCloudBlockBlob])> in
        // step 1: list all the files from azure and hold the info in a buffer
        // This is not really optimal as it takes ages and requires heaps of memory but meh, works well enough
        let prefix = entry.target.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!
        
        var count = 0
        class DictWrapper { // deliberately box the dictionary to prevent copying during accumulation
            var blobs = [String:AZSCloudBlockBlob]()
            func add(_ name: String, _ blob: AZSCloudBlockBlob) {
                blobs[name] = blob
            }
        }
        let blobDict = DictWrapper()
        return container
            .listBlobs(prefix: prefix, batchSize: 1000)
            .flatMap { blobs -> Observable<AZSCloudBlockBlob> in
                count += blobs.count
                print("\(prefix): found \(count)")
                return Observable.from(blobs)
        }
        .reduce(blobDict) { (dict, blob) -> DictWrapper in
            blobDict.add(blob.blobName!, blob)
            return blobDict
        }
        .map { blobs in (container: container, entry: entry, blobs: blobs.blobs) }
    }
    .flatMap { arg -> Observable<FileOperation> in
        processBackupEntry(arg.entry, container: arg.container, blobs: arg.blobs)
    }
    .subscribe(onNext: { fileOperation in
        if fileOperation.type != .alreadyUpToDate { // just noise and slows things down
            print("\(fileOperation.file.relativePath) -> \(String(describing: fileOperation.type))")
        }
    })
    
    
} catch let err {
    print("Can't connect to azure, error \(err)")
    exit(988)
}

// Run GCD main dispatcher, this function never returns, call exit() elsewhere to quit the program or it will hang
dispatchMain()
