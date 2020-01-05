# AzBackup
This is a macOS Utility to backup files to Azure Blob storage.

I wrote it in about 5 hours, and half of that was figuring out how to get Combine to do what I wanted to and compiling the Azure iOS Storage SDK for macOS and modern Xcode correctly.

My main motivation was that I hit the 200gb limit on the free version of CloudBerry Backup, which is what I was using previously. A sensible person (or a company with discretionary budget) would simply pay the $50 USD for the pro version, however this kind of thing is a bit of fun and I can save $50. You should probably use CloudBerry Backup instead of this as well :-)

It's designed to do just what I need it to do, not be an all-purpose tool for all users.
It doesn't have all the things that a professional app would need such as logging, a GUI, or even a sensible code structure. Throwing all the code in main.swift is fine for pet projects but never for anything serious.

NOTE: restores are not handled. While you can easily use something like Azure Storage Explorer to pull down all your recovered files, the modification times will be wrong.
Modification time is stored in azure blob storage metadata so we'd need to have some code which read that metadata at the time it was pulling down the files, and then applied it

I expect I'd write that code if I ever needed to do a restore.

## Future considerations:
Uploading one file at a time is quite slow. Perhaps we could do N concurrent uploads or something
