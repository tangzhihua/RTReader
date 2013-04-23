
#import "FileUploadHttpConnection.h"
#import "HTTPMessage.h"
#import "HTTPDataResponse.h"
#import "DDNumber.h"
#import "HTTPLogging.h"

#import "MultipartFormDataParser.h"
#import "MultipartMessageHeaderField.h"
#import "HTTPDynamicFileResponse.h"
#import "HTTPFileResponse.h"
#import <netdb.h>
#import <arpa/inet.h>
// Log levels : off, error, warn, info, verbose
// Other flags: trace
static const int httpLogLevel = HTTP_LOG_LEVEL_VERBOSE; // | HTTP_LOG_FLAG_TRACE;


/**
 * All we have to do is override appropriate methods in HTTPConnection.
 **/

@implementation FileUploadHttpConnection {
  long long total;
	long long current;
}

static void (^_completionHandler)(NSString * filePath);
static void (^_progressHandler)(NSString * fileName, float progress);

+ (void)onFileUploaded:(void(^)(NSString * filePath))completionHandler {
  _completionHandler = completionHandler;
}
+ (void)onFileUploadProgress:(void(^)(NSString * fileName, float progress))progressHandler {
  _progressHandler = progressHandler;
}

// retun the host name
+ (NSString *)hostname
{
  char baseHostName[256];
  int success = gethostname(baseHostName, 255);
  if (success != 0) return nil;
  baseHostName[255] = '\0';
  
#if !TARGET_IPHONE_SIMULATOR
  return [NSString stringWithFormat:@"%s.local", baseHostName];
#else
  return [NSString stringWithFormat:@"%s", baseHostName];
#endif
}
+ (NSString *)localIPAddress
{
  struct hostent *host = gethostbyname([[self hostname] UTF8String]);
  if (!host) {herror("resolv"); return nil;}
  struct in_addr **list = (struct in_addr **)host->h_addr_list;
  return [NSString stringWithCString:inet_ntoa(*list[0]) encoding:NSUTF8StringEncoding];
}

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path
{
	HTTPLogTrace();
	
	// Add support for POST
	
	if ([method isEqualToString:@"POST"])
	{
		if ([path isEqualToString:@"/upload.html"])
		{
			return YES;
		}
	}
	
	return [super supportsMethod:method atPath:path];
}

- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)path
{
	HTTPLogTrace();
	
	// Inform HTTP server that we expect a body to accompany a POST request
	
	if([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.html"]) {
    // here we need to make sure, boundary is set in header
    NSString* contentType = [request headerField:@"Content-Type"];
    NSUInteger paramsSeparator = [contentType rangeOfString:@";"].location;
    if( NSNotFound == paramsSeparator ) {
      return NO;
    }
    if( paramsSeparator >= contentType.length - 1 ) {
      return NO;
    }
    NSString* type = [contentType substringToIndex:paramsSeparator];
    if( ![type isEqualToString:@"multipart/form-data"] ) {
      // we expect multipart/form-data content type
      return NO;
    }
    
		// enumerate all params in content-type, and find boundary there
    NSArray* params = [[contentType substringFromIndex:paramsSeparator + 1] componentsSeparatedByString:@";"];
    for( NSString* param in params ) {
      paramsSeparator = [param rangeOfString:@"="].location;
      if( (NSNotFound == paramsSeparator) || paramsSeparator >= param.length - 1 ) {
        continue;
      }
      NSString* paramName = [param substringWithRange:NSMakeRange(1, paramsSeparator-1)];
      NSString* paramValue = [param substringFromIndex:paramsSeparator+1];
      
      if( [paramName isEqualToString: @"boundary"] ) {
        // let's separate the boundary from content-type, to make it more handy to handle
        [request setHeaderField:@"boundary" value:paramValue];
      }
    }
    // check if boundary specified
    if( nil == [request headerField:@"boundary"] )  {
      return NO;
    }
    return YES;
  }
	return [super expectsRequestBodyFromMethod:method atPath:path];
}

- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path
{
	HTTPLogTrace();
	
	if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/upload.html"])
	{
    
		// this method will generate response with links to uploaded file
		NSMutableString* filesStr = [[NSMutableString alloc] init];
    
		for( NSString* filePath in uploadedFiles ) {
			//generate links
      //			[filesStr appendFormat:@"<a href=\"%@\"> %@ </a><br/>",filePath, [filePath lastPathComponent]];
      [filesStr appendString: [filePath lastPathComponent]];
		}
		NSString* templatePath = [[config documentRoot] stringByAppendingPathComponent:@"upload.html"];
		NSDictionary* replacementDict = [NSDictionary dictionaryWithObject:filesStr forKey:@"MyFiles"];
		// use dynamic file response to apply our links to response template
		return [[HTTPDynamicFileResponse alloc] initWithFilePath:templatePath forConnection:self separator:@"%" replacementDictionary:replacementDict];
	}
	if( [method isEqualToString:@"GET"] && [path hasPrefix:@"/upload/"] ) {
		// let download the uploaded files
		return [[HTTPFileResponse alloc] initWithFilePath: [[config documentRoot] stringByAppendingString:path] forConnection:self];
	}
	
	return [super httpResponseForMethod:method URI:path];
}

- (void)prepareForBodyWithSize:(UInt64)contentLength
{
	HTTPLogTrace();
	
	// set up mime parser
  NSString* boundary = [request headerField:@"boundary"];
  parser = [[MultipartFormDataParser alloc] initWithBoundary:boundary formEncoding:NSUTF8StringEncoding];
  parser.delegate = self;
  
	uploadedFiles = [[NSMutableArray alloc] init];
  total = contentLength;
}

- (void)processBodyData:(NSData *)postDataChunk
{
	HTTPLogTrace();
  // append data to the parser. It will invoke callbacks to let us handle
  // parsed data.
  [parser appendData:postDataChunk];
  current += postDataChunk.length;
  
  if(storeFile && _progressHandler)  {
    dispatch_async(dispatch_get_main_queue(), ^{
      _progressHandler([[uploadedFiles lastObject] lastPathComponent],(float)current/total);
    });
  }
}


//-----------------------------------------------------------------
#pragma mark multipart form data parser delegate


- (void) processStartOfPartWithHeader:(MultipartMessageHeader*) header {
	// in this sample, we are not interested in parts, other then file parts.
	// check content disposition to find out filename
  
  MultipartMessageHeaderField* disposition = [header.fields objectForKey:@"Content-Disposition"];
	NSString* filename = [[disposition.params objectForKey:@"filename"] lastPathComponent];
	
  if ( (nil == filename) || [filename isEqualToString: @""] ) {
    // it's either not a file part, or
		// an empty form sent. we won't handle it.
		return;
	}
  //	NSString* uploadDirPath = [[config documentRoot] stringByAppendingPathComponent:@"upload"];
  NSString* uploadDirPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"upload"];
  
	BOOL isDir = YES;
	if (![[NSFileManager defaultManager]fileExistsAtPath:uploadDirPath isDirectory:&isDir ]) {
		[[NSFileManager defaultManager]createDirectoryAtPath:uploadDirPath withIntermediateDirectories:YES attributes:nil error:nil];
	}
	
  NSString* filePath = [uploadDirPath stringByAppendingPathComponent: filename];
  if( [[NSFileManager defaultManager] fileExistsAtPath:filePath] ) {
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
  }
  HTTPLogVerbose(@"Saving file to %@", filePath);
  if(![[NSFileManager defaultManager] createDirectoryAtPath:uploadDirPath withIntermediateDirectories:true attributes:nil error:nil]) {
    HTTPLogError(@"Could not create directory at path: %@", filePath);
  }
  if(![[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil]) {
    HTTPLogError(@"Could not create file at path: %@", filePath);
  }
  storeFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
  [uploadedFiles addObject: filePath];
  
//  if(_progressHandler){
//    _progressHandler(filename, 0);
//  }
}


- (void) processContent:(NSData*) data WithHeader:(MultipartMessageHeader*) header
{
	// here we just write the output from parser to the file.
	if( storeFile ) {
		[storeFile writeData:data];
	}
}

- (void) processEndOfPartWithHeader:(MultipartMessageHeader*) header
{
	// as the file part is over, we close the file.
	[storeFile closeFile];
  if(storeFile){
    current = 0;
    total = 0;
  }
  if(storeFile && _completionHandler){
    dispatch_async(dispatch_get_main_queue(), ^{
      _completionHandler([uploadedFiles lastObject]);
    });
  }
	storeFile = nil;
}

- (void) processPreambleData:(NSData*) data
{
  // if we are interested in preamble data, we could process it here.
  
}

- (void) processEpilogueData:(NSData*) data
{
  // if we are interested in epilogue data, we could process it here.
  
}

@end
