# AzBackup
This is a macOS Utility to backup files to Azure Blob storage.

I originally wrote it to play with Combine and the Azure Storage SDK.

My main motivation was that I hit the 200gb limit on the free version of CloudBerry Backup, which is what I was using previously. A sensible person (or a company with discretionary budget) would simply pay the $50 USD for the pro version, however this kind of thing is a bit of fun and I can save $50. You should probably use CloudBerry Backup instead of this as well :-)

It's designed to do just what I need it to do, not be an all-purpose tool for all users.
It doesn't have all the things that a professional app would need such as logging, a GUI, or even a sensible code structure. Throwing all the code in main.swift is fine for pet projects but never for anything serious.

NOTE: restores are not handled. While you can easily use something like Azure Storage Explorer to pull down all your recovered files, the modification times will be wrong.
Modification time is stored in azure blob storage metadata so we'd need to have some code which read that metadata at the time it was pulling down the files, and then applied it

I expect I'd write that code if I ever needed to do a restore.

## Notes
Initially it only supported a single upload at a time, however it now runs up to 3 uploads concurrently (UploadManager.concurrentUploads = 3) because otherwise it's really really slow. 
There seems to be quite a bit of handshaking/overhead involved in uploading a single file to azure so if you have lots of small files, it doesn't come anywhere near close to saturating
the network connection of my 20mbit fibre upload at this time. Concurrent uploads helps a lot.

## Known Issues
This uses the azure storage sdk's uploadBlob function, to upload a single file at a time; it does not handle partial uploads or resume partially-uploaded files.
This sometimes then encounters request timeouts when uploading very large files.
Most likely workaround would be to have fewer concurrent uploads, or to increase the timeout.
