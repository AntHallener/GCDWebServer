/*
 Copyright (c) 2012-2014, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <SystemConfiguration/SystemConfiguration.h>
#endif

#import "GCDWebUploader.h"

#import "GCDWebServerDataRequest.h"
#import "GCDWebServerMultiPartFormRequest.h"
#import "GCDWebServerURLEncodedFormRequest.h"

#import "GCDWebServerDataResponse.h"
#import "GCDWebServerErrorResponse.h"
#import "GCDWebServerFileResponse.h"

@interface GCDWebUploader () {
@private
  NSString* _uploadDirectory;
  id<GCDWebUploaderDelegate> __unsafe_unretained _delegate;
  NSArray* _allowedExtensions;
  BOOL _showHidden;
  NSString* _title;
  NSString* _header;
  NSString* _prologue;
  NSString* _epilogue;
  NSString* _footer;
}
@end

@implementation GCDWebUploader (Methods)

- (BOOL)_checkFileExtension:(NSString*)fileName {
  if (_allowedExtensions && ![_allowedExtensions containsObject:[[fileName pathExtension] lowercaseString]]) {
    return NO;
  }
  return YES;
}

- (NSString*) _uniquePathForPath:(NSString*)path {
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSString* directory = [path stringByDeletingLastPathComponent];
    NSString* file = [path lastPathComponent];
    NSString* base = [file stringByDeletingPathExtension];
    NSString* extension = [file pathExtension];
    int retries = 0;
    do {
      if (extension.length) {
        path = [directory stringByAppendingPathComponent:[[base stringByAppendingFormat:@" (%i)", ++retries] stringByAppendingPathExtension:extension]];
      } else {
        path = [directory stringByAppendingPathComponent:[base stringByAppendingFormat:@" (%i)", ++retries]];
      }
    } while ([[NSFileManager defaultManager] fileExistsAtPath:path]);
  }
  return path;
}

- (GCDWebServerResponse*)listDirectory:(GCDWebServerRequest*)request {
  NSString* relativePath = [[request query] objectForKey:@"path"];
  NSString* absolutePath = [_uploadDirectory stringByAppendingPathComponent:relativePath];
  BOOL isDirectory;
  if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
  }
  if (!isDirectory) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"\"%@\" is not a directory", relativePath];
  }
  
  NSError* error = nil;
  NSArray* contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:absolutePath error:&error];
  if (contents == nil) {
    return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed listing directory \"%@\"", relativePath];
  }
  
  NSMutableArray* array = [NSMutableArray array];
  for (NSString* item in [contents sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
    if (_showHidden || ![item hasPrefix:@"."]) {
      NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[absolutePath stringByAppendingPathComponent:item] error:NULL];
      NSString* type = [attributes objectForKey:NSFileType];
      if ([type isEqualToString:NSFileTypeRegular] && [self _checkFileExtension:item]) {
        [array addObject:@{
                           @"path": [relativePath stringByAppendingPathComponent:item],
                           @"name": item,
                           @"size": [attributes objectForKey:NSFileSize]
                           }];
      } else if ([type isEqualToString:NSFileTypeDirectory]) {
        [array addObject:@{
                           @"path": [[relativePath stringByAppendingPathComponent:item] stringByAppendingString:@"/"],
                           @"name": item
                           }];
      }
    }
  }
  return [GCDWebServerDataResponse responseWithJSONObject:array];
}

- (GCDWebServerResponse*)downloadFile:(GCDWebServerRequest*)request {
  NSString* relativePath = [[request query] objectForKey:@"path"];
  NSString* absolutePath = [_uploadDirectory stringByAppendingPathComponent:relativePath];
  BOOL isDirectory;
  if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath isDirectory:&isDirectory]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
  }
  if (isDirectory) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"\"%@\" is a directory", relativePath];
  }
  
  if ([_delegate respondsToSelector:@selector(webUploader:didDownloadFileAtPath:  )]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_delegate webUploader:self didDownloadFileAtPath:absolutePath];
    });
  }
  return [GCDWebServerFileResponse responseWithFile:absolutePath isAttachment:YES];
}

- (GCDWebServerResponse*)uploadFile:(GCDWebServerMultiPartFormRequest*)request {
  NSRange range = [[request.headers objectForKey:@"Accept"] rangeOfString:@"application/json" options:NSCaseInsensitiveSearch];
  NSString* contentType = (range.location != NSNotFound ? @"application/json" : @"text/plain; charset=utf-8");  // Required when using iFrame transport (see https://github.com/blueimp/jQuery-File-Upload/wiki/Setup)
  
  GCDWebServerMultiPartFile* file = [request.files objectForKey:@"files[]"];
  if ((!_showHidden && [file.fileName hasPrefix:@"."]) || ![self _checkFileExtension:file.fileName]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Uploaded file name \"%@\" is not allowed", file.fileName];
  }
  NSString* relativePath = [(GCDWebServerMultiPartArgument*)[request.arguments objectForKey:@"path"] string];
  NSString* absolutePath = [self _uniquePathForPath:[[_uploadDirectory stringByAppendingPathComponent:relativePath] stringByAppendingPathComponent:file.fileName]];
  
  if (![self shouldUploadFileAtPath:absolutePath withTemporaryFile:file.temporaryPath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Uploading file \"%@\" to \"%@\" is not allowed", file.fileName, relativePath];
  }
  
  NSError* error = nil;
  if (![[NSFileManager defaultManager] moveItemAtPath:file.temporaryPath toPath:absolutePath error:&error]) {
    return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving uploaded file to \"%@\"", relativePath];
  }
  
  if ([_delegate respondsToSelector:@selector(webUploader:didUploadFileAtPath:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_delegate webUploader:self didUploadFileAtPath:absolutePath];
    });
  }
  return [GCDWebServerDataResponse responseWithJSONObject:@{} contentType:contentType];
}

- (GCDWebServerResponse*)moveItem:(GCDWebServerURLEncodedFormRequest*)request {
  NSString* oldRelativePath = [request.arguments objectForKey:@"oldPath"];
  NSString* oldAbsolutePath = [_uploadDirectory stringByAppendingPathComponent:oldRelativePath];
  BOOL isDirectory;
  if (![[NSFileManager defaultManager] fileExistsAtPath:oldAbsolutePath isDirectory:&isDirectory]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", oldRelativePath];
  }
  
  NSString* newRelativePath = [request.arguments objectForKey:@"newPath"];
  NSString* newAbsolutePath = [self _uniquePathForPath:[_uploadDirectory stringByAppendingPathComponent:newRelativePath]];
  if (!_showHidden) {
    for (NSString* component in [newRelativePath pathComponents]) {
      if ([component hasPrefix:@"."]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_BadRequest message:@"Item path \"%@\" is not allowed", newRelativePath];
      }
    }
  }
  if (!isDirectory && ![self _checkFileExtension:newRelativePath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Item path \"%@\" is not allowed", newRelativePath];
  }
  
  if (![self shouldMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Moving \"%@\" to \"%@\" is not allowed", oldRelativePath, newRelativePath];
  }
  
  [[NSFileManager defaultManager] createDirectoryAtPath:[newAbsolutePath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
  NSError* error = nil;
  if (![[NSFileManager defaultManager] moveItemAtPath:oldAbsolutePath toPath:newAbsolutePath error:&error]) {
    return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed moving \"%@\" to \"%@\"", oldRelativePath, newRelativePath];
  }
  
  if ([_delegate respondsToSelector:@selector(webUploader:didMoveItemFromPath:toPath:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_delegate webUploader:self didMoveItemFromPath:oldAbsolutePath toPath:newAbsolutePath];
    });
  }
  return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

- (GCDWebServerResponse*)deleteItem:(GCDWebServerURLEncodedFormRequest*)request {
  NSString* relativePath = [request.arguments objectForKey:@"path"];
  NSString* absolutePath = [_uploadDirectory stringByAppendingPathComponent:relativePath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:absolutePath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_NotFound message:@"\"%@\" does not exist", relativePath];
  }
  
  if (![self shouldDeleteItemAtPath:absolutePath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Deleting \"%@\" is not allowed", relativePath];
  }
  
  NSError* error = nil;
  if (![[NSFileManager defaultManager] removeItemAtPath:absolutePath error:&error]) {
    return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed deleting \"%@\"", relativePath];
  }
  
  if ([_delegate respondsToSelector:@selector(webUploader:didDeleteItemAtPath:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_delegate webUploader:self didDeleteItemAtPath:absolutePath];
    });
  }
  return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

- (GCDWebServerResponse*)createDirectory:(GCDWebServerURLEncodedFormRequest*)request {
  NSString* relativePath = [request.arguments objectForKey:@"path"];
  NSString* absolutePath = [self _uniquePathForPath:[_uploadDirectory stringByAppendingPathComponent:relativePath]];
  if (!_showHidden) {
    for (NSString* component in [relativePath pathComponents]) {
      if ([component hasPrefix:@"."]) {
        return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Directory path \"%@\" is not allowed", relativePath];
      }
    }
  }
  
  if (![self shouldCreateDirectoryAtPath:absolutePath]) {
    return [GCDWebServerErrorResponse responseWithClientError:kGCDWebServerHTTPStatusCode_Forbidden message:@"Creating directory \"%@\" is not allowed", relativePath];
  }
  
  NSError* error = nil;
  if (![[NSFileManager defaultManager] createDirectoryAtPath:absolutePath withIntermediateDirectories:YES attributes:nil error:&error]) {
    return [GCDWebServerErrorResponse responseWithServerError:kGCDWebServerHTTPStatusCode_InternalServerError underlyingError:error message:@"Failed creating directory \"%@\"", relativePath];
  }
  
  if ([_delegate respondsToSelector:@selector(webUploader:didCreateDirectoryAtPath:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [_delegate webUploader:self didCreateDirectoryAtPath:absolutePath];
    });
  }
  return [GCDWebServerDataResponse responseWithJSONObject:@{}];
}

@end

@implementation GCDWebUploader

@synthesize uploadDirectory=_uploadDirectory, delegate=_delegate, allowedFileExtensions=_allowedExtensions, showHiddenFiles=_showHidden,
            title=_title, header=_header, prologue=_prologue, epilogue=_epilogue, footer=_footer;

- (id)initWithUploadDirectory:(NSString*)path {
  if ((self = [super init])) {
    NSBundle* siteBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"GCDWebUploader" ofType:@"bundle"]];
    if (siteBundle == nil) {
#if !__has_feature(objc_arc)
      [self release];
#endif
      return nil;
    }
    _uploadDirectory = [[path stringByStandardizingPath] copy];
    GCDWebUploader* __unsafe_unretained server = self;
    
    // Resource files
    [self addGETHandlerForBasePath:@"/" directoryPath:[siteBundle resourcePath] indexFilename:nil cacheAge:3600 allowRangeRequests:NO];
    
    // Web page
    [self addHandlerForMethod:@"GET" path:@"/" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      
#if TARGET_OS_IPHONE
      NSString* device = [[UIDevice currentDevice] name];
#else
#if __has_feature(objc_arc)
      NSString* device = CFBridgingRelease(SCDynamicStoreCopyComputerName(NULL, NULL));
#else
      NSString* device = [(id)SCDynamicStoreCopyComputerName(NULL, NULL) autorelease];
#endif
#endif
      NSString* title = server.title;
      if (title == nil) {
        title = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
#if !TARGET_OS_IPHONE
        if (title == nil) {
          title = [[NSProcessInfo processInfo] processName];
        }
#endif
      }
      NSString* header = server.header;
      if (header == nil) {
        header = title;
      }
      NSString* prologue = server.prologue;
      if (prologue == nil) {
        prologue = [siteBundle localizedStringForKey:@"PROLOGUE" value:@"" table:nil];
      }
      NSString* epilogue = server.epilogue;
      if (epilogue == nil) {
        epilogue = [siteBundle localizedStringForKey:@"EPILOGUE" value:@"" table:nil];
      }
      NSString* footer = server.footer;
      if (footer == nil) {
        NSString* name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        NSString* version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
#if !TARGET_OS_IPHONE
        if (!name && !version) {
          name = @"OS X";
          version = [[NSProcessInfo processInfo] operatingSystemVersionString];
        }
#endif
        footer = [NSString stringWithFormat:[siteBundle localizedStringForKey:@"FOOTER_FORMAT" value:@"" table:nil], name, version];
      }
      return [GCDWebServerDataResponse responseWithHTMLTemplate:[siteBundle pathForResource:@"index" ofType:@"html"]
                                                      variables:@{
                                                                  @"device": device,
                                                                  @"title": title,
                                                                  @"header": header,
                                                                  @"prologue": prologue,
                                                                  @"epilogue": epilogue,
                                                                  @"footer": footer
                                                                  }];
      
    }];
    
    // File listing
    [self addHandlerForMethod:@"GET" path:@"/list" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server listDirectory:request];
    }];
    
    // File download
    [self addHandlerForMethod:@"GET" path:@"/download" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server downloadFile:request];
    }];
    
    // File upload
    [self addHandlerForMethod:@"POST" path:@"/upload" requestClass:[GCDWebServerMultiPartFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server uploadFile:(GCDWebServerMultiPartFormRequest*)request];
    }];
    
    // File and folder moving
    [self addHandlerForMethod:@"POST" path:@"/move" requestClass:[GCDWebServerURLEncodedFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server moveItem:(GCDWebServerURLEncodedFormRequest*)request];
    }];
    
    // File and folder deletion
    [self addHandlerForMethod:@"POST" path:@"/delete" requestClass:[GCDWebServerURLEncodedFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server deleteItem:(GCDWebServerURLEncodedFormRequest*)request];
    }];
    
    // Directory creation
    [self addHandlerForMethod:@"POST" path:@"/create" requestClass:[GCDWebServerURLEncodedFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
      return [server createDirectory:(GCDWebServerURLEncodedFormRequest*)request];
    }];
    
  }
  return self;
}

#if !__has_feature(objc_arc)

- (void)dealloc {
  [_uploadDirectory release];
  [_allowedExtensions release];
  [_title release];
  [_header release];
  [_prologue release];
  [_epilogue release];
  [_footer release];
  
  [super dealloc];
}

#endif

@end

@implementation GCDWebUploader (Subclassing)

- (BOOL)shouldUploadFileAtPath:(NSString*)path withTemporaryFile:(NSString*)tempPath {
  return YES;
}

- (BOOL)shouldMoveItemFromPath:(NSString*)fromPath toPath:(NSString*)toPath {
  return YES;
}

- (BOOL)shouldDeleteItemAtPath:(NSString*)path {
  return YES;
}

- (BOOL)shouldCreateDirectoryAtPath:(NSString*)path {
  return YES;
}

@end
