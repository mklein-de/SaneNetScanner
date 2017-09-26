//
//  CSSaneNetScanner.m
//  SaneNetScanner
//
//  Created by Christian Speich on 05.08.12.
//  Copyright (c) 2012 Christian Speich. All rights reserved.
//

#import "CSSaneNetScanner.h"

#import "CSSequentialDataProvider.h"

#import "CSSaneOption.h"
#import "CSSaneOptionRangeConstraint.h"

#include "sane/sane.h"

typedef enum {
    ProgressNotificationsNone,
    ProgressNotificationsWithData,
    ProgressNotificationsWithoutData
} ProgressNotifications;

@interface CSSaneNetScanner ()

@property (nonatomic, strong) NSString* prettyName;

@property (nonatomic, strong) NSString* deviceName;
@property (nonatomic, strong) NSArray* saneAdresses;

@property (nonatomic, strong) NSMutableDictionary* deviceProperties;
@property (nonatomic, strong) NSDictionary* saneOptions;

@property (nonatomic) BOOL open;

@property (nonatomic) SANE_Handle saneHandle;

@property (nonatomic) ProgressNotifications progressNotifications;
@property (nonatomic) BOOL produceFinalScan;

@property (nonatomic) NSString* colorSyncMode;

@property (nonatomic, assign) CGColorSpaceRef colorSpace;

@property (nonatomic) NSURL* rawFileURL;
@property (nonatomic) NSURL* documentURL;
@property (nonatomic) NSString* documentType;

- (UInt32) numberOfComponents;

@end

@interface CSSaneNetScanner (Progress)

- (void) showWarmUpMessage;
- (void) doneWarmUpMessage;
- (void) pageDoneMessage;
- (void) scanDoneMessage;

- (void) sendTransactionCanceledMessage;

@end

@interface CSSaneNetScanner (ICARawFile)

- (void) createColorSpaceWithSaneParameters:(SANE_Parameters*)parameters;
- (void) writeHeaderToFile:(NSFileHandle*)handle
        withSaneParameters:(SANE_Parameters*)parameters;

- (void) resaveRawFileAt:(NSURL*)url
                  asType:(NSString*)type
                   toURL:(NSURL*)url
          saneParameters:(SANE_Parameters*)parameters;

@end

@implementation CSSaneNetScanner

- (id) initWithParameters:(NSDictionary*)params;
{
    self = [super init];
    if (self) {
        Log(@"Params %@", params);

        self.open = NO;
        self.saneHandle = 0;
        self.prettyName = params[(NSString*)kICABonjourServiceNameKey];
        self.deviceName = [[NSString alloc] initWithData:params[(NSString*)kICABonjourTXTRecordKey][@"deviceName"]
                                             encoding:NSUTF8StringEncoding];
        self.saneAdresses = @[];
        if (params[@"ipAddress"])
            self.saneAdresses = [self.saneAdresses arrayByAddingObject:params[@"ipAddress"]];
        if (params[@"ipAddress_v6"])
            self.saneAdresses = [self.saneAdresses arrayByAddingObject:
                                 [NSString stringWithFormat:@"[%@]", params[@"ipAddress_v6"]]];
    }
    return self;
}

- (void)dealloc
{
    if (self.open || self.saneHandle != 0) {
        Log(@"Deallocating but sane handle is still open");
        sane_close(self.saneHandle);
        self.saneHandle = 0;
    }
}

- (ICAError) openSession:(ICD_ScannerOpenSessionPB*)params
{
    Log(@"Open session");
    if (self.open)
        return kICAInvalidSessionErr;

    SANE_Handle handle;
    SANE_Status status;

    for (NSString* address in self.saneAdresses) {
        NSString* fullName = [NSString stringWithFormat:@"%@:%@", address, self.deviceName];

        Log(@"Try open to %@", fullName);
        status = sane_open([fullName UTF8String], &handle);

        // If open succeeded we can quit tring
        if (status == SANE_STATUS_GOOD)
            break;
        else {
            Log(@"Failed width %s", sane_strstatus(status));
        }
    }

    if (status == SANE_STATUS_GOOD) {
        self.open = YES;
        self.saneHandle = handle;

        return noErr;
    }
    else {
        return kICADeviceInternalErr;
    }
}

- (ICAError) closeSession:(ICD_ScannerCloseSessionPB*)params
{
    Log(@"Close session");

    if (!self.open)
        return kICAInvalidSessionErr;

    sane_close(self.saneHandle);
    self.saneHandle = 0;
    self.open = NO;

    return noErr;
}

- (ICAError) addPropertiesToDictionary:(NSMutableDictionary*)dict
{
    // Add kICAUserAssignedDeviceNameKey.  Since this key is a simple NSString,
    // the value may be of any length.  This key supercedes any name already
    // provided in the device information before, which is limited to 32 characters.
    dict[(NSString*)kICAUserAssignedDeviceNameKey] = self.prettyName;

    // Add key indicating that the module supports using the ICA Raw File
    // as a backing store for image io
    dict[@"supportsICARawFileFormat"] = @1;

    Log(@"addPropertiesToDictionary:%@", dict);

    return noErr;
}

- (ICAError) getParameters:(ICD_ScannerGetParametersPB*)params
{
    Log(@"Get params");
    NSMutableDictionary* dict = (__bridge NSMutableDictionary*)(params->theDict);

    if (!dict)
        return paramErr;

    NSMutableDictionary* deviceDict = [NSMutableDictionary dictionary];
    /*
    NSMutableDictionary* deviceDict = [@{
    @"functionalUnits": @{
    @"availableFunctionalUnitTypes" : @[ @0 ]
    },
    @"selectedFunctionalUnitType": @0,

    @"ICAP_SUPPORTEDSIZES": @{ @"current": @1, @"default": @1, @"type": @"TWON_ENUMERATION", @"value": @[ @1, @2, @3, @4, @5, @10, @0 ]},

    @"ICAP_UNITS": @{ @"current": @0, @"default": @0, @"type": @"TWON_ENUMERATION", @"value": @[ @0, @1, @5 ] },

    } mutableCopy];
    */

    self.saneOptions = [CSSaneOption saneOptionsForHandle:self.saneHandle];

    // Export the resolution
    if (self.saneOptions[kSaneScanResolution]) {
        NSMutableDictionary* d = [NSMutableDictionary dictionary];
        CSSaneOption* option = self.saneOptions[kSaneScanResolution];

        [option.constraint addToDeviceDictionary:d];
        d[@"current"] = option.value;
        d[@"default"] = option.value;

        deviceDict[@"ICAP_XRESOLUTION"] = d;
        deviceDict[@"ICAP_YRESOLUTION"] = d;
    }
    else {
        Log(@"WARN: scanner does not support resolutions!?");
    }

    // Export the physical width
    for (NSString* name in @[ kSaneTopLeftX, kSaneBottomRightX ]) {
        if (self.saneOptions[name]) {
            // Convert to inch (will be reported as mm)
            CSSaneOption* option = self.saneOptions[name];
            CSSaneOptionRangeConstraint* constraint = (CSSaneOptionRangeConstraint*)option.constraint;
            double width = ([constraint.maxValue doubleValue] - [constraint.minValue doubleValue])/25.4;

            // If already exists look if the new width is smaller and update if so
            if (deviceDict[@"ICAP_PHYSICALWIDTH"]) {
                if ([deviceDict[@"ICAP_PHYSICALWIDTH"][@"value"] doubleValue] > width) {
                    deviceDict[@"ICAP_PHYSICALWIDTH"] = @{
                    @"type": @"TWON_ONEVALUE",
                    @"value": @(width)
                    };
                }
            }
            // Not present yes, so set
            else {
                deviceDict[@"ICAP_PHYSICALWIDTH"] = @{
                @"type": @"TWON_ONEVALUE",
                @"value": @(width)
                };
            }
        }
    }

    // Export the physical height
    for (NSString* name in @[ kSaneTopLeftY, kSaneBottomRightY ]) {
        if (self.saneOptions[name]) {
            // Convert to inch (will be reported as mm)
            CSSaneOption* option = self.saneOptions[name];
            CSSaneOptionRangeConstraint* constraint = (CSSaneOptionRangeConstraint*)option.constraint;
            double height = ([constraint.maxValue doubleValue] - [constraint.minValue doubleValue])/25.4;

            // If already exists look if the new width is smaller and update if so
            if (deviceDict[@"ICAP_PHYSICALHEIGHT"]) {
                if ([deviceDict[@"ICAP_PHYSICALHEIGHT"][@"value"] doubleValue] > height) {
                    deviceDict[@"ICAP_PHYSICALHEIGHT"] = @{
                    @"type": @"TWON_ONEVALUE",
                    @"value": @(height)
                    };
                }
            }
            // Not present yes, so set
            else {
                deviceDict[@"ICAP_PHYSICALHEIGHT"] = @{
                @"type": @"TWON_ONEVALUE",
                @"value": @(height)
                };
            }
        }
    }

    // The bitdepth was not an option from the device
    // now we have to infer from the scan mode.
    if (deviceDict[@"ICAP_BITDEPTH"] == nil) {
        deviceDict[@"ICAP_BITDEPTH"] =  @{
            @"current": @1,
            @"default": @1,
            @"type":
            @"TWON_ENUMERATION",
            @"value": @[ @1, @8 ]
        };
    }

    dict[@"device"] = deviceDict;
    self.deviceProperties = deviceDict;

    Log(@"Updated parameters %@", dict);

    return noErr;
}

- (ICAError) setParameters:(ICD_ScannerSetParametersPB*)params
{
    Log(@"Set params: %@", params->theDict);
    NSDictionary* dict = ((__bridge NSDictionary *)(params->theDict))[@"userScanArea"];


    {
        NSString* documentPath = dict[@"document folder"];
        documentPath = [documentPath stringByAppendingPathComponent:dict[@"document name"]];
        documentPath = [documentPath stringByAppendingPathExtension:dict[@"document extension"]];

        if (documentPath) {
            self.documentURL = [NSURL fileURLWithPath:documentPath];
            self.documentType = dict[@"document format"];
        }

        // RAW is not requested, so we need a temporary raw file
        if (![self.documentType isEqualToString:@"com.apple.ica.raw"] && !self.rawFileURL) {
            self.rawFileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingFormat:@"scan-raw-%@.ica", [[NSUUID UUID] UUIDString]]];
        }
    }

    int unit = [dict[@"ICAP_UNITS"][@"value"] intValue];

    if (dict[@"ColorSyncMode"]) {
        CSSaneOption* option = self.saneOptions[kSaneScanMode];

        NSString* syncMode = dict[@"ColorSyncMode"];
        if ([syncMode isEqualToString:@"scanner.reflective.RGB.positive"]) {
            option.value = @"Color";
        }
        else if ([syncMode isEqualToString:@"scanner.reflective.Gray.positive"]) {
            option.value = @"Gray";
        }
        else {
            Log(@"Unkown colorsyncmode %@", syncMode);
        }
    }

    // X and Y resolution are always equal
    if (dict[@"ICAP_XRESOLUTION"] || dict[@"ICAP_XRESOLUTION"]) {
        CSSaneOption* option = self.saneOptions[kSaneScanResolution];

        if (unit == 1 /* Centimeter */) {
            // Convert dpcm to dpi
            // 1 dpcm = 2,54 dpi
            option.value = @([dict[@"ICAP_XRESOLUTION"][@"value"] doubleValue] / 2.54);
        }
        else if (unit == 0 /* Inches */) {
            // Great nothing to to here =)
            option.value = dict[@"ICAP_XRESOLUTION"][@"value"];
        }
        else {
            Log(@"Unsupported unit");
        }
    }

    if (dict[@"scan mode"]) {
        CSSaneOption* option = self.saneOptions[kSanePreview];

        if ([dict[@"scan mode"] isEqualToString:@"overview"]) {
            option.value = @1;
        }
        else {
            option.value = @0;
        }
    }

    if (dict[@"offsetX"]) {
        CSSaneOption* option = self.saneOptions[kSaneTopLeftX];

        if (unit == 1 /* Centimeter */) {
            // Convert cm to mm
            option.value = @([dict[@"offsetX"] doubleValue] * 10);
        }
        else if (unit == 0 /* Inches */) {
            // Convert inches to mm
            option.value = @([dict[@"offsetX"] doubleValue] * 25.4);
        }
    }

    if (dict[@"offsetY"]) {
        CSSaneOption* option = self.saneOptions[kSaneTopLeftY];

        if (unit == 1 /* Centimeter */) {
            // Convert cm to mm
            option.value = @([dict[@"offsetY"] doubleValue] * 10);
        }
        else if (unit == 0 /* Inches */) {
            // Convert inches to mm
            option.value = @([dict[@"offsetY"] doubleValue] * 25.4);
        }
    }

    if (dict[@"width"]) {
        CSSaneOption* option = self.saneOptions[kSaneBottomRightX];

        double value = [dict[@"offsetX"] doubleValue] + [dict[@"width"] doubleValue];
        if (unit == 1 /* Centimeter */) {
            // Convert cm to mm
            option.value = @(value * 10);
        }
        else if (unit == 0 /* Inches */) {
            // Convert inches to mm
            option.value = @(value * 25.4);
        }
    }

    if (dict[@"height"]) {
        CSSaneOption* option = self.saneOptions[kSaneBottomRightY];

        double value = [dict[@"offsetY"] doubleValue] + [dict[@"height"] doubleValue];
        if (unit == 1 /* Centimeter */) {
            // Convert cm to mm
            option.value = @(value * 10);
        }
        else if (unit == 0 /* Inches */) {
            // Convert inches to mm
            option.value = @(value * 25.4);
        }
    }

    if ([dict[@"progressNotificationWithData"] boolValue]) {
        self.progressNotifications = ProgressNotificationsWithData;
    }
    else if ([dict[@"progressNotificationNoData"] boolValue]) {
        self.progressNotifications = ProgressNotificationsWithoutData;
    }
    else {
        self.progressNotifications = ProgressNotificationsNone;
    }

    if ([dict[@"scan mode"] isEqualToString:@"overview"])
        self.produceFinalScan = NO;
    else
        self.produceFinalScan = YES;

    self.colorSyncMode = dict[@"ColorSyncMode"];

    return noErr;
}

- (ICAError) status:(ICD_ScannerStatusPB*)params
{
    Log( @"status");

    return paramErr;
}

- (ICAError) start:(ICD_ScannerStartPB*)params
{
    Log(@"Start");
    SANE_Status status;
    SANE_Parameters parameters;

    [self showWarmUpMessage];
    Log(@"sane_start");
    status = sane_start(self.saneHandle);

    if (status != SANE_STATUS_GOOD) {
        Log(@"sane_start failed: %s", sane_strstatus(status));
        return kICADeviceInternalErr;
    }

    Log(@"sane_get_parameters");
    status = sane_get_parameters(self.saneHandle, &parameters);

    if (status != SANE_STATUS_GOOD) {
        Log(@"sane_get_parameters failed: %s", sane_strstatus(status));
        sane_cancel(self.saneHandle);
        return kICADeviceInternalErr;
    }
    Log(@"sane_get_parameters: last_frame=%u, bytes_per_line=%u, pixels_per_line=%u, lines=%u, depth=%u", parameters.last_frame, parameters.bytes_per_line, parameters.pixels_per_line, parameters.lines, parameters.depth);

    [self doneWarmUpMessage];

    Log(@"Prepare raw file");
    NSFileHandle* rawFileHandle;

    if (![self.documentType isEqualToString:@"com.apple.ica.raw"]) {
        [[NSFileManager defaultManager] createFileAtPath:[self.rawFileURL path]
                                                contents:nil
                                              attributes:nil];
        rawFileHandle = [NSFileHandle fileHandleForWritingAtPath:[self.rawFileURL path]];
    }
    else {
        [[NSFileManager defaultManager] createFileAtPath:[self.documentURL path]
                                                contents:nil
                                              attributes:nil];
        rawFileHandle = [NSFileHandle fileHandleForWritingAtPath:[self.documentURL path]];
    }

    [self createColorSpaceWithSaneParameters:&parameters];

    // Write header
    [self writeHeaderToFile:rawFileHandle
         withSaneParameters:&parameters];


    Log(@"Prepare buffers");
    int bufferSize;
    int bufferdRows;
    NSMutableData* buffer;

    // Choose buffer size
    //
    //  Use a buffer size around 50KiB.
    //  the size will be aligned to row boundries
    bufferdRows = MIN(500*1025 / parameters.bytes_per_line, parameters.lines);
    bufferSize = bufferdRows * parameters.bytes_per_line;

    buffer = [NSMutableData dataWithLength:bufferSize];

    Log(@"Choose to buffer %u rows (%u in size)", bufferdRows, bufferSize);

    Log(@"Begin reading");
    int row = 0;

    do {
        // Fill the buffer
        unsigned char* b = [buffer mutableBytes];
        int filled = 0;

        do {
            SANE_Int readBytes;
            status = sane_read(self.saneHandle,
                               &b[filled],
                               bufferSize - filled,
                               &readBytes);

            if (status == SANE_STATUS_EOF)
                break;
            else if (status != SANE_STATUS_GOOD) {
                NSLog(@"Read error");
                return kICADeviceInternalErr;
            }

            filled += readBytes;
        } while (filled < bufferSize);
        // Shrink the buffer if not fully filled
        // (may happen for the last block)
        [buffer setLength:filled];

        // Means we have to save the data somewhere
        if (self.produceFinalScan) {
            [rawFileHandle writeData:buffer];
        }

        // Notify the image capture kit that we made progress
        if (self.progressNotifications != ProgressNotificationsNone) {
            ICASendNotificationPB notePB = {};
            NSMutableDictionary* d = [@{
                                      (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
                                      (id)kICANotificationTypeKey: (id)kICANotificationTypeScanProgressStatus
                                      } mutableCopy];

            notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)d;

            // Add image with data
            if (self.progressNotifications == ProgressNotificationsWithData) {
                ICDAddImageInfoToNotificationDictionary(notePB.notificationDictionary,
                                                        parameters.pixels_per_line,
                                                        parameters.lines,
                                                        parameters.bytes_per_line,
                                                        row,
                                                        bufferdRows,
                                                        (UInt32)[buffer length],
                                                        (void*)[buffer bytes]);
            }
            // Add image info without data
            else {
                ICDAddImageInfoToNotificationDictionary(notePB.notificationDictionary,
                                                        parameters.pixels_per_line,
                                                        parameters.lines,
                                                        parameters.bytes_per_line,
                                                        row,
                                                        bufferdRows,
                                                        0,
                                                        NULL);
            }

            // Send the progress and check if the user
            // canceled the scan
            if (ICDSendNotificationAndWaitForReply(&notePB) == noErr)
            {
                if (notePB.replyCode == userCanceledErr) {
                    Log(@"User canceled. Clean up...");
                    sane_cancel(self.saneHandle);

                    [self sendTransactionCanceledMessage];
                    return noErr;
                }
            }
        }
        Log(@"Read line %i", row);
        row+=bufferdRows;
    } while (status == SANE_STATUS_GOOD);

    // We now need to read the raw file and produce a formatted version
    if (self.produceFinalScan) {
        if (![self.documentType isEqualToString:@"com.apple.ica.raw"]) {
            [self resaveRawFileAt:self.rawFileURL
                           asType:self.documentType
                            toURL:self.documentURL
                   saneParameters:&parameters];
        }
    }

    sane_cancel(self.saneHandle);

    Log(@"Done...");
    [self pageDoneMessage];
    [self scanDoneMessage];

    return noErr;
}

- (UInt32) numberOfComponents
{
    NSString* scanMode = [self.saneOptions[kSaneScanMode] value];
    UInt32 numberOfComponents = 0;

    if ([scanMode isEqualToString:@"Color"])
        numberOfComponents = 3;
    else if ([scanMode isEqualToString:@"Gray"] || [scanMode isEqualToString:@"Lineart"])
        numberOfComponents = 1;

    return numberOfComponents;
}

@end

@implementation CSSaneNetScanner (Progress)

- (void) showWarmUpMessage
{
    ICASendNotificationPB notePB = {};
    NSMutableDictionary* dict = [@{
            (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
            (id)kICANotificationTypeKey: (id)kICANotificationTypeDeviceStatusInfo,
            (id)kICANotificationSubTypeKey: (id)kICANotificationSubTypeWarmUpStarted
    } mutableCopy];
    notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)dict;

    ICDSendNotification( &notePB );
}

- (void) doneWarmUpMessage
{
    ICASendNotificationPB notePB = {};
    NSMutableDictionary* dict = [@{
        (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
        (id)kICANotificationTypeKey: (id)kICANotificationTypeDeviceStatusInfo,
        (id)kICANotificationSubTypeKey: (id)kICANotificationSubTypeWarmUpDone
    } mutableCopy];
    notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)dict;

    ICDSendNotification(&notePB);
}

- (void) pageDoneMessage
{
    ICASendNotificationPB notePB = {};
    NSMutableDictionary* dict = [@{
        (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
        (id)kICANotificationTypeKey: (id)kICANotificationTypeScannerPageDone,
    } mutableCopy];
    notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)dict;

    if (self.documentURL)
        ((__bridge NSMutableDictionary*)notePB.notificationDictionary)[(id)kICANotificationScannerDocumentNameKey] = [self.documentURL path];


    ICDSendNotification( &notePB );
}

- (void) scanDoneMessage
{
    ICASendNotificationPB notePB = {};
    NSMutableDictionary* dict = [@{
        (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
        (id)kICANotificationTypeKey: (id)kICANotificationTypeScannerScanDone
    } mutableCopy];
    notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)dict;

    ICDSendNotification( &notePB );
}

- (void) sendTransactionCanceledMessage
{
    ICASendNotificationPB notePB = {};
    NSMutableDictionary* dict = [@{
        (id)kICANotificationICAObjectKey: @(self.scannerObjectInfo->icaObject),
        (id)kICANotificationTypeKey: (id)kICANotificationTypeTransactionCanceled
    } mutableCopy];
    notePB.notificationDictionary = (__bridge CFMutableDictionaryRef)dict;

    ICDSendNotification( &notePB );
}

@end

@implementation CSSaneNetScanner (ICARawFile)

- (void) createColorSpaceWithSaneParameters:(SANE_Parameters*)parameters
{
    NSString* profilePath = [NSTemporaryDirectory() stringByAppendingFormat:@"vs-%d",getpid()];

    self.colorSpace = ICDCreateColorSpace([self numberOfComponents] * parameters->depth,
                                          [self numberOfComponents],
                                          self.scannerObjectInfo->icaObject,
                                          (__bridge CFStringRef)(self.colorSyncMode),
                                          NULL,
                                          (char*)[profilePath fileSystemRepresentation]);
}

- (void) writeHeaderToFile:(NSFileHandle*)handle
        withSaneParameters:(SANE_Parameters*)parameters
{
    ICARawFileHeader h;

    h.imageDataOffset      = sizeof(ICARawFileHeader);
    h.version              = 1;
    h.imageWidth           = parameters->pixels_per_line;
    h.imageHeight          = parameters->lines;
    h.bytesPerRow          = parameters->bytes_per_line;
    h.bitsPerComponent     = parameters->depth;
    h.bitsPerPixel         = [self numberOfComponents] * parameters->depth;
    h.numberOfComponents   = [self numberOfComponents];
    h.cgColorSpaceModel    = CGColorSpaceGetModel(self.colorSpace);
    h.bitmapInfo           = kCGImageAlphaNone;
    h.dpi                  = 75;
    h.orientation          = 1;
    strlcpy(h.colorSyncModeStr, [self.colorSyncMode UTF8String], sizeof(h.colorSyncModeStr));

    [handle writeData:[NSData dataWithBytesNoCopy:&h
                                           length:sizeof(ICARawFileHeader)
                                     freeWhenDone:NO]];
}

- (void) resaveRawFileAt:(NSURL*)url
                  asType:(NSString*)type
                   toURL:(NSURL*)destUrl
          saneParameters:(SANE_Parameters*)parameters
{
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)destUrl, (__bridge CFStringRef)type, 1, nil);
    CGDataProviderRef provider = [CSSequentialDataProvider createDataProviderWithFileAtURL:url
                                                                             andHardOffset:sizeof(ICARawFileHeader)];

    CGImageRef image = CGImageCreate(parameters->pixels_per_line,
                                     parameters->lines,
                                     parameters->depth,
                                     [self numberOfComponents] * parameters->depth,
                                     parameters->bytes_per_line,
                                     self.colorSpace,
                                     kCGImageAlphaNone,
                                     provider,
                                     NULL,
                                     NO, kCGRenderingIntentDefault);

    CGImageDestinationAddImage(dest, image, nil);


    CGImageDestinationFinalize(dest);
}

@end
