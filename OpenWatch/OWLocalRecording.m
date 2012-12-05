//
//  OWLocalRecording.m
//  OpenWatch
//
//  Created by Christopher Ballinger on 12/3/12.
//  Copyright (c) 2012 OpenWatch FPC. All rights reserved.
//

#import "OWLocalRecording.h"
#import "OWSettingsController.h"
#import "OWCaptureAPIClient.h"
#import "OWLocationController.h"

#define kHQFileName @"hq.mp4"
#define kAllFilesKey @"all_files"
#define kUploadingKey @"uploading"
#define kFailedKey @"failed"
#define kCompletedKey @"completed"
#define kUploadStateKey @"upload_state"
#define kRecordingStartDateKey @"recording_start"
#define kRecordingEndDateKey @"recording_end"
#define kLocationStartKey @"start_location"
#define kLocationEndKey @"end_location"
#define kLatitudeKey @"latitude"
#define kLongitudeKey @"longitude"
#define kAltitudeKey @"altitude"
#define kRecordingKey @"recording"
#define kHorizontalAccuracyKey @"horizontal_accuracy"
#define kVerticalAccuracyKey @"vertical_accuracy"
#define kSpeedKey @"speed"
#define kCourseKey @"course"
#define kTimestampKey @"timestamp"
#define kTitleKey @"title"
#define kDescriptionKey @"description"
#define kUUIDKey @"uuid"
#define kMetadataFileName @"metadata.json"

@implementation OWLocalRecording

@dynamic localRecordingPath;
@dynamic hqFileUploadState;
@dynamic segments;

- (NSString *)newUUID
{
    CFUUIDRef theUUID = CFUUIDCreate(NULL);
    CFStringRef string = CFUUIDCreateString(NULL, theUUID);
    CFRelease(theUUID);
    return (__bridge_transfer NSString *)string;
}

+ (OWLocalRecording*) recordingWithPath:(NSString *)path {
    OWLocalRecording *recording = [OWLocalRecording MR_findFirstByAttribute:@"localRecordingPath" withValue:path];
    if (!recording) {
        recording = [OWLocalRecording MR_createEntity];
        recording.localRecordingPath = path;
        OWUser *user = [[[OWSettingsController sharedInstance] account] user];
        recording.user = user;
        NSManagedObjectContext *context = [NSManagedObjectContext MR_contextForCurrentThread];
        NSError *error = nil;
        BOOL success = [context obtainPermanentIDsForObjects:@[recording] error:&error];
        if (error || !success) {
            NSLog(@"Error convert to permanent ID: %@", [error userInfo]);
        }
        [context MR_saveNestedContexts];
    }
    return recording;
}

- (void) setUploadState:(OWFileUploadState)uploadState forFileAtURL :(NSURL *)url {
    NSString *path = [url path];
    NSString *fileName = [path lastPathComponent];
    NSManagedObjectContext *context = [NSManagedObjectContext MR_contextForCurrentThread];
    if ([[path lastPathComponent] isEqualToString:kHQFileName]) {
        self.hqFileUploadState = @(uploadState);
        [context MR_saveNestedContexts];
        return;
    }
    
    OWRecordingSegment *segment = [OWRecordingSegment MR_findFirstByAttribute:@"filePath" withValue:path];
    if (segment) {
        segment.fileUploadState = uploadState;
    } else {
        segment = [OWRecordingSegment MR_createEntity];
        segment.filePath = path;
        segment.fileUploadState = uploadState;
        segment.recording = self;
        segment.fileName = fileName;
    }
    [context MR_saveNestedContexts];
}

- (OWFileUploadState)uploadStateForFileAtURL:(NSURL*)url {
    NSString *path = [url path];
    
    if ([[path lastPathComponent] isEqualToString:kHQFileName]) {
        return [self.hqFileUploadState unsignedIntegerValue];
    }
    
    OWRecordingSegment *segment = [OWRecordingSegment MR_findFirstByAttribute:@"filePath" withValue:path];
    if (!segment) {
        return OWFileUploadStateUnknown;
    }
    return segment.fileUploadState;
}


- (NSDictionary*) dictionaryRepresentation {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:[self newMetadataDictionary]];
    NSMutableArray *allFiles = [NSMutableArray array];
    
    for (OWRecordingSegment *segment in self.segments) {
        [allFiles addObject:segment.fileName];
    }
    
    [dictionary setObject:allFiles forKey:kAllFilesKey];
    return dictionary;
}

- (NSDictionary*) newMetadataDictionary {
    NSMutableDictionary *newMetadataDictionary = [NSMutableDictionary dictionary];
    if (self.uuid) {
        [newMetadataDictionary setObject:[self.uuid copy] forKey:kUUIDKey];
    }
    if (self.startDate) {
        [newMetadataDictionary setObject:@([self.startDate timeIntervalSince1970]) forKey:kRecordingStartDateKey];
    }
    if (self.endDate) {
        [newMetadataDictionary setObject:@([self.endDate timeIntervalSince1970]) forKey:kRecordingEndDateKey];
    }
    if (self.title) {
        [newMetadataDictionary setObject:[self.title copy] forKey:kTitleKey];
    }
    if (self.recordingDescription) {
        [newMetadataDictionary setObject:[self.recordingDescription copy] forKey:kDescriptionKey];
    }
    if ([self locationIsValid:self.startLocation]) {
        NSDictionary *startLocationDictionary = [self locationDictionaryForLocation:self.startLocation];
        [newMetadataDictionary setObject:startLocationDictionary forKey:kLocationStartKey];
    }
    if ([self locationIsValid:self.endLocation]) {
        NSDictionary *endLocationDictionary = [self locationDictionaryForLocation:self.endLocation];
        [newMetadataDictionary setObject:endLocationDictionary forKey:kLocationEndKey];
    }
    return newMetadataDictionary;
}

- (BOOL) locationIsValid:(CLLocation*)location {
    if (location.coordinate.latitude == 0.0f && location.coordinate.longitude == 0.0f) {
        return NO;
    }
    return YES;
}

- (NSDictionary*) locationDictionaryForLocation:(CLLocation*)location {
    NSMutableDictionary *locationDictionary = [NSMutableDictionary dictionaryWithCapacity:2];
    [locationDictionary setObject:@(location.coordinate.latitude) forKey:kLatitudeKey];
    [locationDictionary setObject:@(location.coordinate.longitude) forKey:kLongitudeKey];
    return locationDictionary;
}

- (void) checkIntegrity {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *recordingFileNames = [fileManager contentsOfDirectoryAtPath:self.localRecordingPath error:&error];
    if (error) {
        NSLog(@"Error getting contents of recording directory: %@", self.localRecordingPath);
    }
        
    BOOL dataHasChanged = NO;
    
    for (NSString *fileName in recordingFileNames) {
        if ([fileName rangeOfString:@"mp4"].location != NSNotFound) {
            NSString *videoPath = [self.localRecordingPath stringByAppendingPathComponent:fileName];
            NSURL *url = [NSURL URLWithString:videoPath];
            OWFileUploadState state = [self uploadStateForFileAtURL:url];
            if (state == OWFileUploadStateUnknown) {
                NSLog(@"Unrecognized file found (%@): %@", self.localRecordingPath, videoPath);
                [self setUploadState:OWFileUploadStateFailed forFileAtURL:url];
                dataHasChanged = YES;
            }
        }
    }
    if (dataHasChanged) {
        [self saveMetadata];
    }
}


- (void) loadMetadataFromDictionary:(NSDictionary*)metadataDictionary {
    NSString *newUUID = [metadataDictionary objectForKey:kUUIDKey];
    if (newUUID) {
        self.uuid = newUUID;
    }
    NSString *newTitle = [metadataDictionary objectForKey:kTitleKey];
    if (newTitle) {
        self.title = newTitle;
    }
    NSString *newDescription = [metadataDictionary objectForKey:kDescriptionKey];
    if (newDescription) {
        self.recordingDescription = newDescription;
    }
    NSNumber *startDateTimestampNumber = [metadataDictionary objectForKey:kRecordingStartDateKey];
    if (startDateTimestampNumber) {
        self.startDate = [NSDate dateWithTimeIntervalSince1970:[startDateTimestampNumber doubleValue]];
    }
    NSNumber *endDateTimestampNumber = [metadataDictionary objectForKey:kRecordingEndDateKey];
    if (endDateTimestampNumber) {
        self.endDate = [NSDate dateWithTimeIntervalSince1970:[endDateTimestampNumber doubleValue]];
    }
    NSDictionary *startLocationDictionary = [metadataDictionary objectForKey:kLocationStartKey];
    if (startLocationDictionary) {
        self.startLocation = [self locationFromLocationDictionary:startLocationDictionary];
    }
    NSDictionary *endLocationDictionary = [metadataDictionary objectForKey:kLocationEndKey];
    if (endLocationDictionary) {
        self.endLocation = [self locationFromLocationDictionary:endLocationDictionary];
    }
}

- (CLLocation*)locationFromLocationDictionary:(NSDictionary*)locationDictionary {
    CLLocationDegrees latitude = [[locationDictionary objectForKey:kLatitudeKey] doubleValue];
    CLLocationDegrees longitude = [[locationDictionary objectForKey:kLongitudeKey] doubleValue];
    return [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
}

- (void) startLocationUpdated:(CLLocation *)location {
    self.startLocation = location;
    [self saveMetadata];
    [[OWCaptureAPIClient sharedClient] updateMetadataForRecording:self.objectID];
}

- (void) startRecording {
    self.startDate = [NSDate date];
    self.uuid = [self newUUID];
    [[OWLocationController sharedInstance] startWithDelegate:self];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:self.localRecordingPath isDirectory:&isDirectory]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:self.localRecordingPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Error creating directory: %@%@", [error localizedDescription], [error userInfo]);
        }
    }
    [self saveMetadata];
    [[OWCaptureAPIClient sharedClient] startedRecording:self.objectID];
}

- (void) stopRecording {
    self.endDate = [NSDate date];
    self.endLocation = [OWLocationController sharedInstance].currentLocation;
    [[OWLocationController sharedInstance] stop];
    [self saveMetadata];
    [[OWCaptureAPIClient sharedClient] finishedRecording:self.objectID];
    [[OWCaptureAPIClient sharedClient] updateMetadataForRecording:self.objectID];
}

- (NSURL*) highQualityURL {
    NSString *movieName = kHQFileName;
    NSString *path = [self.localRecordingPath stringByAppendingPathComponent:movieName];
    NSURL *newMovieURL = [NSURL fileURLWithPath:path];
    return newMovieURL;
}

- (NSURL*) urlForNextSegment {
    NSString *movieName = [NSString stringWithFormat:@"%d.mp4", [self.segments count]+1];
    NSString *path = [self.localRecordingPath stringByAppendingPathComponent:movieName];
    NSURL *newMovieURL = [NSURL fileURLWithPath:path];
    return newMovieURL;
}

- (NSUInteger) failedFileCount {
    return [[self failedFileSegments] count];
}

- (NSSet*) failedFileSegments {
    NSPredicate *predicate =
    [NSPredicate predicateWithFormat:@"fileUploadState == %d", OWFileUploadStateFailed];
    NSSet *filteredSet = [self.segments filteredSetUsingPredicate:predicate];
    return filteredSet;
}

- (NSUInteger) completedFileCount {
    NSPredicate *predicate =
    [NSPredicate predicateWithFormat:@"fileUploadState == %d", OWFileUploadStateCompleted];
    NSSet *filteredSet = [self.segments filteredSetUsingPredicate:predicate];
    return [filteredSet count];
}

- (NSUInteger) totalFileCount {
    return [self.segments count];
}

- (BOOL) isHighQualityFileUploaded {
    return ([self.hqFileUploadState unsignedIntegerValue] == OWFileUploadStateCompleted);
}

- (NSArray*) failedFileUploadURLs {
    NSSet *failedFileSegments = [self failedFileSegments];
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:[failedFileSegments count]];
    for (OWRecordingSegment *segment in failedFileSegments) {
        NSString *path = segment.filePath;
        [urls addObject:[NSURL fileURLWithPath:path]];
    }
    return urls;
}


@end