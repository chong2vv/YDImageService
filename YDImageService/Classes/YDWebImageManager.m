//
//  YDWebImageManager.m
//  YDImageService
//
//  Created by 王远东 on 2022/8/18.
//  Copyright © 2022 wangyuandong. All rights reserved.
//

#import "YDWebImageManager.h"
#import "YYImageCache.h"
#import <YYWebImage/YYWebImageOperation.h>
#import "YYImageCoder.h"
#import <objc/runtime.h>
#import "YYWebImageOperation+YDNetworkThread.h"

#define kNetworkIndicatorDelay (1/30.0)
#define WeakObj(o) autoreleasepool{} __weak typeof(o) o##Weak = o
#define StrongObj(o) autoreleasepool{} __strong typeof(o) o = o##Weak

/// Returns nil in App Extension.
static UIApplication *_YDSharedApplication(void) {
    static BOOL isAppExtension = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"UIApplication");
        if(!cls || ![cls respondsToSelector:@selector(sharedApplication)]) isAppExtension = YES;
        if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) isAppExtension = YES;
    });
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    return isAppExtension ? nil : [UIApplication performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
}

@interface YDImageSafeMutableArray : NSMutableArray

@end

@interface _YDWebImageApplicationNetworkIndicatorInfo : NSObject
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong) NSTimer *timer;
@end
@implementation _YDWebImageApplicationNetworkIndicatorInfo
@end

@interface YDWebImageManager ()

@property (nonatomic, strong) YDImageSafeMutableArray *downloadArray;
@property (nonatomic, strong) YDImageSafeMutableArray *queueArray;
@property (atomic,    strong) NSDate *lastDownloadDate;
@property (nonatomic, strong) NSTimer *timer;

@end

@implementation YDWebImageManager

+ (instancetype)sharedManager {
    static YDWebImageManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YYImageCache *cache = [YYImageCache sharedCache];
        NSOperationQueue *queue = [NSOperationQueue new];
        if ([queue respondsToSelector:@selector(setQualityOfService:)]) {
            queue.qualityOfService = NSQualityOfServiceBackground;
        }
        manager = [[self alloc] initWithCache:cache queue:queue];
    });
    return manager;
}

- (instancetype)init {
    @throw [NSException exceptionWithName:@"YYWebImageManager init error" reason:@"Use the designated initializer to init." userInfo:nil];
    return [self initWithCache:nil queue:nil];
}

- (instancetype)initWithCache:(YYImageCache *)cache queue:(NSOperationQueue *)queue{
    self = [super init];
    if (!self) return nil;
    _cache = cache;
    self.queue = queue;
    queue.maxConcurrentOperationCount = 3;
    self.maxConcurrent = 3;
    _timeout = 15.0;
    if (YYImageWebPAvailable()) {
        _headers = @{ @"Accept" : @"image/webp,image/*;q=0.8" };
    } else {
        _headers = @{ @"Accept" : @"image/*;q=0.8" };
    }
    return self;
}

- (void)setQueue:(NSOperationQueue *)queue {
    _queue = queue;
    if (queue == nil) {
        self.downloadArray = [YDImageSafeMutableArray new];
        self.queueArray = [YDImageSafeMutableArray new];
        // 开启定时器检测任务，如下载任务出现异常卡死，可自行恢复
//        [self performSelector:@selector(addTimer) withObject:nil afterDelay:1.0];
        [self performSelector:@selector(addTimer) onThread:[YYWebImageOperation networkThread] withObject:nil waitUntilDone:YES];
    }else {
        self.downloadArray = nil;
        self.queueArray = nil;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(addTimer) object:nil];
        if (self.timer) {
            [self.timer invalidate];
            self.timer = nil;
        }
    }
}

- (void)addTimer {
    self.timer = [NSTimer timerWithTimeInterval:self.timeout target:self selector:@selector(reSetQueue) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)reSetQueue {
    NSTimeInterval time = [self.lastDownloadDate timeIntervalSinceNow];
    if (fabs(time) > self.timeout) {
        static NSInteger count = 0;
        if (self.downloadArray.count >= self.maxConcurrent && self.queueArray.count > 0) {
            if (count >= 3) {
                [self.downloadArray removeAllObjects];
            }
            YYWebImageOperation *op = self.queueArray.firstObject;
            if (op) {
                [self.downloadArray addObject:op];
                [self.queueArray removeObject:op];
                self.lastDownloadDate = [NSDate new];
            }
            count += 1;
            [op start];
        }else {
            count = 0;
        }
    }
}

- (YYWebImageOperation *)requestImageWithURL:(NSURL *)url options:(YYWebImageOptions)options progress:(YYWebImageProgressBlock)progress transform:(YYWebImageTransformBlock)transform completion:(YYWebImageCompletionBlock)completion {
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = _timeout;
    request.HTTPShouldHandleCookies = (options & YYWebImageOptionHandleCookies) != 0;
    request.allHTTPHeaderFields = [self headersForURL:url];
    request.HTTPShouldUsePipelining = YES;
    request.cachePolicy = (options & YYWebImageOptionUseNSURLCache) ?
        NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
    
    @WeakObj(self);
    YYWebImageOperation *operation =
    [[YYWebImageOperation alloc] initWithRequest:request options:options cache:_cache cacheKey:[self cacheKeyForURL:url] progress:progress transform:(transform ? transform : _sharedTransformBlock) completion:^(UIImage *image, NSURL *url, YYWebImageFromType from, YYWebImageStage stage, NSError * error) {
        @StrongObj(self);
        if (completion) {completion(image,url,from,stage,error);}
        if (self.queue)  return;
        if (stage == YYWebImageStageFinished) {
            YYWebImageOperation *op = self.queueArray.firstObject;
            if (op) {
                [self.downloadArray addObject:op];
                [self.queueArray removeObject:op];
                self.lastDownloadDate = [NSDate new];
                [op start];
            }
        }
        // 删除最后处理，删除就会打破循环导致释放
        __block YYWebImageOperation *opfinish = nil;
        [self.downloadArray enumerateObjectsUsingBlock:^(YYWebImageOperation *obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (obj.request == request) {
                opfinish = obj;
                *stop = YES;
            }
        }];
        [self.downloadArray removeObject:opfinish];
    }];

    if (_username && _password) {
        operation.credential = [NSURLCredential credentialWithUser:_username password:_password persistence:NSURLCredentialPersistenceForSession];
    }
    if (operation) {
        NSOperationQueue *queue = _queue;
        if (queue) {
            [queue addOperation:operation];
        } else {
            if (self.downloadArray.count < self.maxConcurrent) {
                [self.downloadArray addObject:operation];
                // 必须有强引用
                self.lastDownloadDate = [NSDate new];
                [operation start];
            }else {
                [self.queueArray insertObject:operation atIndex:0];
            }
        }
    }
    return operation;
}

- (NSDictionary *)headersForURL:(NSURL *)url {
    if (!url) return nil;
    return _headersFilter ? _headersFilter(url, _headers) : _headers;
}

- (NSString *)cacheKeyForURL:(NSURL *)url {
    if (!url) return nil;
    return _cacheKeyFilter ? _cacheKeyFilter(url) : url.absoluteString;
}

#pragma mark Network Indicator

+ (_YDWebImageApplicationNetworkIndicatorInfo *)_networkIndicatorInfo {
    return objc_getAssociatedObject(self, @selector(_networkIndicatorInfo));
}

+ (void)_setNetworkIndicatorInfo:(_YDWebImageApplicationNetworkIndicatorInfo *)info {
    objc_setAssociatedObject(self, @selector(_networkIndicatorInfo), info, OBJC_ASSOCIATION_RETAIN);
}

+ (void)_delaySetActivity:(NSTimer *)timer {
    UIApplication *app = _YDSharedApplication();
    if (!app) return;
    
    NSNumber *visiable = timer.userInfo;
    if (app.networkActivityIndicatorVisible != visiable.boolValue) {
        [app setNetworkActivityIndicatorVisible:visiable.boolValue];
    }
    [timer invalidate];
}

+ (void)_changeNetworkActivityCount:(NSInteger)delta {
    if (!_YDSharedApplication()) return;
    
    void (^block)(void) = ^{
        _YDWebImageApplicationNetworkIndicatorInfo *info = [self _networkIndicatorInfo];
        if (!info) {
            info = [_YDWebImageApplicationNetworkIndicatorInfo new];
            [self _setNetworkIndicatorInfo:info];
        }
        NSInteger count = info.count;
        count += delta;
        info.count = count;
        [info.timer invalidate];
        info.timer = [NSTimer timerWithTimeInterval:kNetworkIndicatorDelay target:self selector:@selector(_delaySetActivity:) userInfo:@(info.count > 0) repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:info.timer forMode:NSRunLoopCommonModes];
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

+ (void)incrementNetworkActivityCount {
    [self _changeNetworkActivityCount:1];
}

+ (void)decrementNetworkActivityCount {
    [self _changeNetworkActivityCount:-1];
}

+ (NSInteger)currentNetworkActivityCount {
    _YDWebImageApplicationNetworkIndicatorInfo *info = [self _networkIndicatorInfo];
    return info.count;
}

@end


#define INIT(...) self = super.init; \
if (!self) return nil; \
__VA_ARGS__; \
if (!_arr) return nil; \
_lock = dispatch_semaphore_create(1); \
return self;

#define shard(...) self = super.init; \
if (!self) return nil; \
__VA_ARGS__; \
if (!_arr) return nil; \
_lock = dispatch_semaphore_create(1); \
return self;

#define LOCK(...) dispatch_semaphore_wait(self->_lock, DISPATCH_TIME_FOREVER); \
__VA_ARGS__; \
dispatch_semaphore_signal(self->_lock);

@implementation YDImageSafeMutableArray{
    NSMutableArray *_arr;  //Subclass a class cluster...
    dispatch_semaphore_t _lock;
}

+ (instancetype)array {
    YDImageSafeMutableArray *arry  = [[YDImageSafeMutableArray alloc] init];
    return arry;
}

+ (instancetype)new {
    YDImageSafeMutableArray *arry  = [[YDImageSafeMutableArray alloc] init];
    return arry;
}

+ (instancetype)arrayWithArray:(NSArray *)array {
    YDImageSafeMutableArray *newArry  = [[YDImageSafeMutableArray alloc] initWithArray:array];
    return newArry;
}

+ (instancetype)arrayWithObjects:(id)firstObj, ... {
    YDImageSafeMutableArray *arry  = [[YDImageSafeMutableArray alloc] initWithObjects:firstObj, nil];
    return arry;
}

- (instancetype)init {
    
    INIT(_arr = [[NSMutableArray alloc] init]);
}

- (instancetype)initWithCapacity:(NSUInteger)numItems {
    INIT(_arr = [[NSMutableArray alloc] initWithCapacity:numItems]);
}

- (instancetype)initWithArray:(NSArray *)array {
    INIT(_arr = [[NSMutableArray alloc] initWithArray:array]);
}

- (instancetype)initWithObjects:(id)firstObj, ... {
    INIT(_arr = [[NSMutableArray alloc] initWithObjects:firstObj, nil]);
}

- (NSUInteger)count {
    LOCK(NSUInteger c = _arr.count);
    return c;
}

- (id)objectAtIndex:(NSUInteger)index {
    LOCK(
        id o = nil;
        if(index < _arr.count) {
            o = [_arr objectAtIndex:index];
        }
    );
    return o;
}

- (void)addObject:(id)anObject
{
    if (anObject == nil) {
        return;
    }
    LOCK([_arr addObject:anObject]);
}

- (void)insertObject:(id)anObject atIndex:(NSUInteger)index
{
    if (anObject == nil) {
        return;
    }
    LOCK([_arr insertObject:anObject atIndex:index]);
}

- (void)removeLastObject
{
    LOCK([_arr removeLastObject]);
}

- (void)removeObjectAtIndex:(NSUInteger)index
{
    LOCK([_arr removeObjectAtIndex:index]);
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject
{
    LOCK([_arr replaceObjectAtIndex:index withObject:anObject]);
}

- (void)removeAllObjects
{
    LOCK([_arr removeAllObjects]);
}

- (void)setObject:(id)obj atIndexedSubscript:(NSUInteger)idx
{
    if (obj == nil) {
        return;
    }
    LOCK([_arr setObject:obj atIndexedSubscript:idx]);
}

- (id)objectAtIndexedSubscript:(NSUInteger)idx
{
    LOCK(id o = [_arr objectAtIndexedSubscript:idx]);
    return o;
}

@end
