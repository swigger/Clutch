//
//  BundleDumpOperation.m
//  Clutch
//
//  Created by Anton Titkov on 11.02.15.
//
//

#import "BundleDumpOperation.h"
#import "Application.h"
#import "GBPrint.h"
#import "optool.h"
#import "NSData+Reading.h"
#import "Device.h"

#import "Dumper.h"

@import ObjectiveC.runtime;

@interface BundleDumpOperation ()
{
    ClutchBundle *_application;
    BOOL _executing, _finished;
    NSString *_binaryDumpPath;
}

+ (NSArray *)availableDumpers;

@end

@implementation BundleDumpOperation

-(void)failedOperation {
    //NSLog(@"listing da operations");
    NSArray* wow = [_application->_dumpQueue operations];
    for (NSOperation* operation in wow) {
        NSLog(@"operation hash %lu", (unsigned long)operation.hash);
    }
    [self completeOperation];
}

- (instancetype)initWithBundle:(ClutchBundle *)application {
    self = [super init];
    if (self) {
        _executing = NO;
        _finished = NO;
        _application = application;
    }
    return self;
}

- (BOOL)isConcurrent {
    return YES;
}

- (BOOL)isExecuting {
    return _executing;
}

- (BOOL)isFinished {
    return _finished;
}

- (void)start {
    // Always check for cancellation before launching the task.
    if ([self isCancelled])
    {
        // Must move the operation to the finished state if it is canceled.
        [self willChangeValueForKey:@"isFinished"];
        _finished = YES;
        [self didChangeValueForKey:@"isFinished"];
        return;
    }
    
    self.completionBlock = ^{
        
    };
    
    // If the operation is not canceled, begin executing the task.
    [self willChangeValueForKey:@"isExecuting"];
    [NSThread detachNewThreadSelector:@selector(main) toTarget:self withObject:nil];
    _executing = YES;
    [self didChangeValueForKey:@"isExecuting"];
}



- (void)main {
    @try {
        
        NSFileManager *_fileManager = [NSFileManager defaultManager];
        
        Binary *originalBinary = _application.executable;
        
        _binaryDumpPath = [originalBinary.workingPath stringByAppendingPathComponent:originalBinary.binaryPath.lastPathComponent];
        
        [_fileManager createDirectoryAtPath:_binaryDumpPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        
        //if (![_application isKindOfClass:[Framework class]])
        [_fileManager copyItemAtPath:originalBinary.binaryPath toPath:_binaryDumpPath error:nil];
                
        NSFileHandle *tmpHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(originalBinary.binaryPath.UTF8String, "r+"))];
        
        NSData *headersData = tmpHandle.availableData;
        
        [tmpHandle closeFile];
        
        if (!headersData) {
            gbprintln(@"Failed to extract headers info from binary %@.",originalBinary);
            [self failedOperation];
            return;
        }
        
        thin_header headers[4];
        uint32_t numHeaders = 0;
        
        headersFromBinary(headers, headersData, &numHeaders);
        
        if (numHeaders == 0) {
            gbprintln(@"No compatible architecture found");
        }
        
        BOOL isFAT = numHeaders > 1;
        
        uint32_t dumpCount = 0;
        
        NSMutableArray *_headersToStrip = [NSMutableArray new];
        
        NSArray *dumpers = [_application isKindOfClass:[Framework class]] ? [self.class availableFrameworkDumpers]: [self.class availableDumpers];
        
        for (uint32_t i = 0; i < numHeaders; i++) {
            
            thin_header macho = headers[i];
            Dumper<BinaryDumpProtocol> *_dumper = nil;
            
            NSLog(@"Finding compatible dumper for binary %@ with arch cputype: %u", originalBinary, macho.header.cputype);
            for (Class dumperClass in dumpers) {
                _dumper = [[dumperClass alloc]initWithHeader:macho originalBinary:originalBinary];
                
                if ([_dumper compatibilityMode] == ArchCompatibilityNotCompatible) {
                    NSLog(@"%@ cannot dump binary %@ (arch %@). Dumper not compatible, finding another dumper",_dumper,originalBinary,[Dumper readableArchFromHeader:macho]);
                    _dumper = nil;
                } else {
                    break;
                }
            }
            
            if (_dumper == nil) {
                NSLog(@"Couldn't find compatible dumper for binary %@ with arch %@. Will have to \"strip\".",originalBinary,[Dumper readableArchFromHeader:macho]);
                NSLog(@"offset %u", macho.offset);
                [_headersToStrip addObject:[NSNumber numberWithUnsignedInt:macho.offset]];
                continue;
            }
            
            NSLog(@"Found compatible dumper %@ for binary %@ with arch %@",_dumper,originalBinary,[Dumper readableArchFromHeader:macho]);
            
            NSFileHandle *_handle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(originalBinary.binaryPath.UTF8String, "r+"))];
            
            _dumper.originalFileHandle = _handle;
            
            BOOL result = [_dumper dumpBinary];
            
            if (result) {
                dumpCount++;
                //SUCCESS(@"Sucessfully dumped %@ segment of %@", [Dumper readableArchFromHeader:macho], originalBinary);
            } else {
                ERROR(@"Failed to dump binary %@ with arch %@",originalBinary,[Dumper readableArchFromHeader:macho]);
            }
            
            [_handle closeFile];
        }
        
        if (!dumpCount) {
            ERROR(@"Failed to dump binary %@",originalBinary);
            [self failedOperation];
            
            return;
        }
        
        
#pragma mark "stripping" headers in FAT binary
        if ([_headersToStrip count] > 0) {
            NSFileHandle *_dumpHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(_binaryDumpPath.UTF8String, "r+"))];
            
            uint32_t magic = [_dumpHandle intAtOffset:0];
            NSData *buffer = [_dumpHandle readDataOfLength:4096];

            [_dumpHandle closeFile];

            bool shouldSwap = magic == MH_CIGAM || magic == MH_CIGAM_64 || magic == FAT_CIGAM;
#define SWAP(NUM) (shouldSwap ? CFSwapInt32(NUM) : NUM)

            NSMutableArray* _headersToKeep = [NSMutableArray new];
            struct fat_header fat = *(struct fat_header *)buffer.bytes;
            fat.nfat_arch = SWAP(fat.nfat_arch);
            
            int offset = sizeof(struct fat_header);
            for (int i = 0; i < fat.nfat_arch; i++) {
                struct fat_arch arch = *(struct fat_arch *)([buffer bytes] + offset);
                NSNumber* archOffset = [NSNumber numberWithUnsignedInt:SWAP(arch.offset)];
                NSLog(@"current offset %u", SWAP(arch.offset));
                if ([_headersToStrip containsObject:archOffset]) {
                    NSLog(@"arch to strip %u %u", SWAP(arch.cpusubtype), SWAP(arch.cputype));
                }
                else {
                    NSValue* archValue = [NSValue value:&arch withObjCType:@encode(struct fat_arch)];
                    [_headersToKeep addObject:archValue];
                    NSLog(@"storing the arch we want to keep %u", SWAP(arch.cpusubtype));
                }
                offset += sizeof(struct fat_arch);
            }
            
#pragma mark lipo ftw
            
            [[NSFileManager defaultManager]moveItemAtPath:_binaryDumpPath toPath:[_binaryDumpPath stringByAppendingPathExtension:@"fatty"] error:nil];
            NSFileHandle *_fattyHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen([_binaryDumpPath stringByAppendingPathExtension:@"fatty"].UTF8String, "r+"))];

            [[NSFileManager defaultManager] createFileAtPath:_binaryDumpPath contents:nil attributes:nil];
            _dumpHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(_binaryDumpPath.UTF8String, "r+"))];

            [_dumpHandle replaceBytesInRange:NSMakeRange(0, sizeof(uint32_t)) withBytes:&magic];
            
            //skip 4 bytes for magic, 4 bytes of nfat_arch
            uint32_t nfat_arch = SWAP([_headersToKeep count]);
            [_dumpHandle replaceBytesInRange:NSMakeRange(sizeof(uint32_t), sizeof(uint32_t)) withBytes:&nfat_arch];
            NSLog(@"changing nfat_arch to %u", SWAP(nfat_arch));
            
            offset = sizeof(struct fat_header);
            
            for (int i = 0,macho_offset = 0; i < _headersToKeep.count; i++) {
                NSValue* archValue = _headersToKeep[i];
                struct fat_arch keepArch;
                [archValue getValue:&keepArch];
                NSLog(@"headers to keep: %u %u", SWAP(keepArch.cpusubtype), SWAP(keepArch.cputype));
                
                int origOffset = SWAP(keepArch.offset);
                
                if (!macho_offset) {
                    macho_offset =  pow(2.0, SWAP(keepArch.align));
                }
                
                keepArch.offset = SWAP(macho_offset);
                
                [_fattyHandle seekToFileOffset:origOffset];
                
                NSData *machOData = [_fattyHandle readDataOfLength:SWAP(keepArch.size)];
                
                [_dumpHandle replaceBytesInRange:NSMakeRange(offset, sizeof(struct fat_arch)) withBytes:&keepArch];
                [_dumpHandle replaceBytesInRange:NSMakeRange(macho_offset, SWAP(keepArch.size)) withBytes:[machOData bytes]];
                offset += sizeof(struct fat_arch);
                macho_offset += SWAP(keepArch.size);
            }
            
            [_dumpHandle closeFile];
            [_fattyHandle closeFile];
            
            [[NSFileManager defaultManager]removeItemAtPath:[_binaryDumpPath stringByAppendingPathExtension:@"fatty"]  error:nil];

            VERBOSE(@"Finished 'stripping' binary %@", originalBinary);
            VERBOSE(@"Note: This binary will be missing some undecryptable architectures\n");
    }
        
        
#pragma mark checking if everything's fine
        if (dumpCount == (numHeaders-_headersToStrip.count))
        {
            NSString *_localPath = [originalBinary.binaryPath stringByReplacingOccurrencesOfString:_application.bundleContainerURL.path withString:@""];
            
            _localPath = [_application.zipPrefix stringByAppendingPathComponent:_localPath];
            
            [@{_binaryDumpPath:_localPath} writeToFile:[originalBinary.workingPath stringByAppendingPathComponent:@"filesToAdd.plist"] atomically:YES];
        }
        
        // Do the main work of the operation here.
        [self completeOperation];
    }
    @catch(...) {
        // Do not rethrow exceptions.
    }
}

- (void)completeOperation {
    [self willChangeValueForKey:@"isFinished"];
    [self willChangeValueForKey:@"isExecuting"];
    _executing = NO;
    _finished = YES;
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

+ (NSArray *)availableDumpers
{
    return @[NSClassFromString(@"ARM64Dumper"),NSClassFromString(@"ARMDumper")];
}

+ (NSArray *)availableFrameworkDumpers
{
    return @[NSClassFromString(@"FrameworkDumper"),NSClassFromString(@"Framework64Dumper")];
}


@end
