//
//  ODBEditor.m
//  B-Quartic

// http://gusmueller.com/odb/

/**
    
    Nov 30- Updates from Eric Blair:
        removed entries from the _filesBeingEdited dictionary when the odb connection is closed.
        added support for handling Save As messages and differentiate between editing a file and editing a string.
 
    Nov 30- Updates from Gus Mueller:
        Added stringByResolvingSymlinksInPath around the file paths passed around, because it seems if you write to
        /tmp/, sometimes you'll get back /private/tmp as a param

*/


#import "NSAppleEventDescriptor-Extensions.h"
#import "ODBEditor.h"
#import "ODBEditorSuite.h"
#import <Carbon/Carbon.h>

NSString * const ODBEditorCustomPathKey		= @"ODBEditorCustomPath";
NSString * const ODBEditorNonRetainedClient = @"ODBEditorNonRetainedClient";
NSString * const ODBEditorClientContext		= @"ODBEditorClientContext";
NSString * const ODBEditorFileName			= @"ODBEditorFileName";
NSString * const ODBEditorIsEditingString	= @"ODBEditorIsEditingString";

@interface ODBEditor(Private)

- (BOOL)_launchExternalEditor;
- (NSString *)_tempFilePathForEditingString:(NSString *)string ODBEditorCustomPathKey:(NSString *)customPathKey processName:(NSString *)processName;
- (BOOL)_editFile:(NSString *)path isEditingString:(BOOL)editingStringFlag options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context;
- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;
- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;

@end

@implementation ODBEditor

static ODBEditor	*_sharedODBEditor;

+ (id)sharedODBEditor {
	if (_sharedODBEditor == nil) {
		_sharedODBEditor = [[ODBEditor alloc] init];
	}
	return _sharedODBEditor;
}

- (id)init {
	self = [super init];
	if (self != nil) {
		UInt32  packageType = 0;
		UInt32  packageCreator = 0;

		if (_sharedODBEditor != nil) {
			[self autorelease];
			[NSException raise: NSInternalInconsistencyException format: @"ODBEditor is a singleton - use [ODBEditor sharedODBEditor]"];
			return nil;
		}
		
		// our initialization
		
		CFBundleGetPackageInfo(CFBundleGetMainBundle(), &packageType, &packageCreator);
		_signature = packageCreator;
		
		[self setEditorBundleIdentifier:@"com.hogbaysoftware.WriteRoom"];
		
		_filePathsBeingEdited = [[NSMutableDictionary alloc] init];
		
		// setup our event handlers
		
		NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
		[appleEventManager setEventHandler: self andSelector: @selector(handleModifiedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
		[appleEventManager setEventHandler: self andSelector: @selector(handleClosedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEClosedFile];
	}
	
	return self;
}

- (void)dealloc {
	NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
	[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
	[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEClosedFile];
	[_editorBundleIdentifier release];
	[_filePathsBeingEdited release];
	[super dealloc];
}

- (void)setEditorBundleIdentifier:(NSString *)bundleIdentifier {
	[_editorBundleIdentifier autorelease];
	_editorBundleIdentifier = [bundleIdentifier copy];
}

- (NSString *)editorBundleIdentifier {
	return _editorBundleIdentifier;
}

- (void)abortEditingFile:(NSString *)path {
	 //#warning REVIEW if we created a temporary file for this session should we try to delete it and/or close it in the editor?

	if (nil == [_filePathsBeingEdited objectForKey: path])
		NSLog(@"ODBEditor: No active editing session for \"%@\"", path);

	 [_filePathsBeingEdited removeObjectForKey: path];
}

- (void)abortAllEditingSessionsForClient:(id)client {
	 //#warning REVIEW if we created a temporary file for this session should we try to delete it and/or close it in the editor?

	BOOL found = NO;
	NSEnumerator *enumerator = [_filePathsBeingEdited objectEnumerator];
	NSMutableArray *keysToRemove = [NSMutableArray array];
	NSDictionary *dictionary = nil;
	
	while (nil != (dictionary = [enumerator nextObject])) {
		id  iterClient = [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		
		if (iterClient == client) {
			found = YES;
			[keysToRemove addObject: [dictionary objectForKey: ODBEditorFileName]];
		}
	}
	
	[_filePathsBeingEdited removeObjectsForKeys: keysToRemove];
	
	if (! found) {
		NSLog(@"ODBEditor: No active editing session for \"%@\"", client);
	}
}

- (BOOL)editFile:(NSString *)path options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
	return [self _editFile: path isEditingString: NO options: options forClient: client context: context];
}

- (BOOL)editString:(NSString *)string options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
	BOOL success = NO;
	NSString *path = [self _tempFilePathForEditingString:string ODBEditorCustomPathKey:[options objectForKey:ODBEditorCustomPathKey] processName:[context objectForKey:@"processName"]];

	if (path != nil) {
		success = [self _editFile: path isEditingString: YES options: options forClient: client context: context];
    }
    
	return success;
}

@end

@implementation ODBEditor(Private)

- (BOOL)_launchExternalEditor {
	BOOL success = NO;
	BOOL running = NO;
	NSWorkspace	*workspace = [NSWorkspace sharedWorkspace];
	NSArray	*runningApplications = [workspace runningApplications];
	NSEnumerator *enumerator = [runningApplications objectEnumerator];
	NSRunningApplication *applicationInfo;
	
	while (nil != (applicationInfo = [enumerator nextObject])) {
       
		NSString *bundleIdentifier = [applicationInfo bundleIdentifier];
		
		if ([bundleIdentifier isEqualToString: _editorBundleIdentifier]) {
			running = YES;
			// bring the app forward
			success = [workspace launchApplication:[[applicationInfo bundleURL] path]];
			break;
		}
	}
	
	if (running == NO) {
		success = [workspace launchAppWithBundleIdentifier: _editorBundleIdentifier options:NSWorkspaceLaunchDefault additionalEventParamDescriptor: nil launchIdentifier:NULL];
	}
	
	return success;
}

- (NSString *)_tempFilePathForEditingString:(NSString *)string ODBEditorCustomPathKey:(NSString *)customPathKey processName:(NSString *)processName {
	static  unsigned sTempFileSequence;
	
	NSString *path = nil;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *escapedPathKey = [customPathKey stringByReplacingOccurrencesOfString:@"/" withString:@"-"];	
	NSString *pathExtension = [escapedPathKey pathExtension];

	for (NSDictionary* programExtension in [[NSUserDefaults standardUserDefaults] objectForKey:@"ProgramExtensions"]) {
		if ([[programExtension objectForKey:@"ProgramName"] isEqualToString:processName]) {
			pathExtension = [programExtension objectForKey:@"FileExtension"];
		}
	}
	
	if ([pathExtension isEqualToString:@""]) {
		pathExtension = @"txt";
	}
	
	do {
		sTempFileSequence++;
		path = [NSString stringWithFormat: @"%@ %03d.%@", [escapedPathKey stringByDeletingPathExtension], sTempFileSequence, pathExtension];
		path = [NSTemporaryDirectory() stringByAppendingPathComponent: path];
	} while ([fileManager fileExistsAtPath:path]);

	NSError *error = nil;
	if (NO == [string writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
		NSLog([error description], nil);
		path = nil;
	}

	return path;
}

- (BOOL)_editFile:(NSString *)path isEditingString:(BOOL)editingStringFlag options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
    // 10.2 fix- akm Nov 30 2004
    path = [path stringByResolvingSymlinksInPath];
    
	BOOL success = NO;
	OSStatus status = noErr;
	NSData *targetBundleID = [_editorBundleIdentifier dataUsingEncoding: NSUTF8StringEncoding];
	NSAppleEventDescriptor *targetDescriptor = [NSAppleEventDescriptor descriptorWithDescriptorType: typeApplicationBundleID data: targetBundleID];
	NSAppleEventDescriptor *appleEvent = [NSAppleEventDescriptor appleEventWithEventClass: kCoreEventClass
																				   eventID: kAEOpenDocuments
																		  targetDescriptor: targetDescriptor
																				  returnID: kAutoGenerateReturnID
																		     transactionID: kAnyTransactionID];
	NSAppleEventDescriptor  *replyDescriptor = nil;
	NSAppleEventDescriptor  *errorDescriptor = nil;
	AEDesc reply = {typeNull, NULL};														
	NSString *customPath = [options objectForKey: ODBEditorCustomPathKey];
	
	[self _launchExternalEditor];
	
	[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithFilePath: path] forKeyword: keyDirectObject];
	[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithTypeCode: _signature] forKeyword: keyFileSender];
	if (customPath != nil)
		[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithString: customPath] forKeyword: keyFileCustomPath];
	
	AESendMessage([appleEvent aeDesc], &reply, kAEWaitReply, kAEDefaultTimeout);
	
	if (status == noErr) {
		replyDescriptor = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: &reply] autorelease];
		errorDescriptor = [replyDescriptor paramDescriptorForKeyword: keyErrorNumber];
		
		if (errorDescriptor != nil) {
			status = [errorDescriptor int32Value];
		}
		
		if (status == noErr) {
			// save off some information that we'll need when we get called back
			
			NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
			
			[dictionary setObject: [NSValue valueWithNonretainedObject: client] forKey: ODBEditorNonRetainedClient];
			if (context != NULL)
				[dictionary setObject: context forKey: ODBEditorClientContext];
			[dictionary setObject: path forKey: ODBEditorFileName];
			[dictionary setObject: [NSNumber numberWithBool: editingStringFlag] forKey: ODBEditorIsEditingString];
			
			[_filePathsBeingEdited setObject: dictionary forKey: path];
		}
	}
	
	success = (status == noErr);
	
	return success;
}

- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor *fpDescriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString *urlString = [[[NSString alloc] initWithData: [fpDescriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *path = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSAppleEventDescriptor	*nfpDescription = [[event paramDescriptorForKeyword: keyNewLocation] coerceToDescriptorType: typeFileURL];
	NSString *newUrlString = [[[NSString alloc] initWithData: [nfpDescription data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *newPath = [[NSURL URLWithString: newUrlString] path];
	NSDictionary *dictionary = nil;
	NSError *error = nil;
	
	dictionary = [_filePathsBeingEdited objectForKey: path];
	
	if (dictionary != nil)
	{
		id  client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		id isString		= [dictionary objectForKey: ODBEditorIsEditingString];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		if(isString) {
			NSString *stringContents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
			if (stringContents) {
				[client odbEditor: self didModifyFileForString: stringContents context: context];
			} else {
				NSLog([error description], nil);
			}
		} else {
			[client odbEditor:self didModifyFile:path newFileLocation:newPath context:context];
		}

		// if we've received a Save As message, remove the file from the list of edited files
		// This may be break compatibility with BBEdit versioner < 6.0, since these versions
		// continue to send notifications after after doing a Save As...
		if(newPath) {
			[_filePathsBeingEdited removeObjectForKey: path];
	    }

	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file.");
	}
}

- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor  *descriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString				*urlString = [[[NSString alloc] initWithData: [descriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString				*fileName = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSDictionary			*dictionary = nil;
	NSError *error = nil;
	
	dictionary = [_filePathsBeingEdited objectForKey: fileName];
	
	if (dictionary != nil) {
		id client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		id isString		= [dictionary objectForKey: ODBEditorIsEditingString];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		if(isString) {
			 NSString	*stringContents = [NSString stringWithContentsOfURL:[NSURL fileURLWithPath:fileName] encoding:NSUTF8StringEncoding error:&error];
			if (stringContents) {
				[client odbEditor: self didCloseFileForString: stringContents context: context];
			} else {
				NSLog([error description], nil);
			}
		} else {
			[client odbEditor:self didClosefile:fileName context:context];
		}
	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file.");
	}
	
	 [_filePathsBeingEdited removeObjectForKey: fileName];
}

@end

