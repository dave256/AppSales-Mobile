//
//  ReviewDownloader.m
//  AppSales
//
//  Created by Nicolas Gomollon on 12/7/15.
//
//

#import "ReviewDownloader.h"
#import "MBProgressHUD.h"
#import "Product.h"
#import "Version.h"
#import "Review.h"
#import "DeveloperResponse.h"

NSString *const kITCReviewAPIRefPageAction     = @"/ra/apps/%@/platforms/%@/reviews/ref";
NSString *const kITCReviewAPIReviewsPageAction = @"/ra/apps/%@/platforms/%@/reviews?sort=REVIEW_SORT_ORDER_MOST_RECENT";

NSString *const kITCReviewAPIPlatformiOS = @"ios";
NSString *const kITCReviewAPIPlatformMac = @"osx";

@interface ReviewDownloader ()

@property (nonatomic, assign) BOOL showingAlert;
@property (nonatomic, weak) MBProgressHUD *hud;

@end

@implementation ReviewDownloader

- (instancetype)initWithProduct:(Product *)product {
	self = [super init];
	if (self) {
		// Initialization code
		_product = product;
		productObjectID = [product.objectID copy];
		moc = [[NSManagedObjectContext alloc] init];
		moc.persistentStoreCoordinator = product.account.managedObjectContext.persistentStoreCoordinator;
		moc.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
		
		productVersions = [[NSMutableDictionary alloc] init];
		existingReviews = [[NSMutableDictionary alloc] init];
		
		[UIApplication sharedApplication].idleTimerDisabled = YES;
		backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
			NSLog(@"Background task for downloading reports has expired!");
		}];
	}
	return self;
}

- (BOOL)isDownloading {
	return _product.account.isDownloadingReports;
}

- (void)start {
	if (!_product.account.password || (_product.account.password.length == 0)) { // Only download reviews for accounts with a login.
		NSLog(@"Login details not set for the account \"%@\". Please go to the account's settings and fill in the missing information.", _product.account.displayName);
		[[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Missing Login Credentials", nil)
									message:[NSString stringWithFormat:NSLocalizedString(@"You have not entered complete login credentials for the account \"%@\". Please go to the account's settings and fill in the missing information.", nil), _product.account.displayName]
											delegate:nil
						  cancelButtonTitle:NSLocalizedString(@"OK", nil)
						  otherButtonTitles:nil] show];
		return;
	}
	
	_product.account.isDownloadingReports = YES;
	[self downloadProgress:0.0f withStatus:NSLocalizedString(@"Logging in...", nil)];
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
		LoginManager *loginManager = [[LoginManager alloc] initWithAccount:_product.account];
		loginManager.shouldDeleteCookies = [[NSUserDefaults standardUserDefaults] boolForKey:kSettingDeleteCookies];
		loginManager.delegate = self;
		[loginManager logIn];
	});
}

- (void)loginSucceeded {
	[self downloadProgress:(1.0f/3.0f) withStatus:NSLocalizedString(@"Downloading reviews...", nil)];
	
	self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
	self.hud.mode = MBProgressHUDModeDeterminateHorizontalBar;
	self.hud.labelText = NSLocalizedString(@"Downloading", nil);
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
		NSString *platform = [_product.platform isEqualToString:kProductPlatformMac] ? kITCReviewAPIPlatformMac : kITCReviewAPIPlatformiOS;
		NSString *refPagePath = [NSString stringWithFormat:kITCReviewAPIRefPageAction, _product.productID, platform];
		NSURL *refPageURL = [NSURL URLWithString:[kITCBaseURL stringByAppendingString:refPagePath]];
		NSData *refPageData = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:refPageURL] returningResponse:nil error:nil];
		
		if (refPageData) {
			NSDictionary *refPage = [NSJSONSerialization JSONObjectWithData:refPageData options:0 error:nil];
			NSString *statusCode = refPage[@"statusCode"];
			if (![statusCode isEqualToString:@"SUCCESS"]) {
				[self showAlert:statusCode withMessages:refPage[@"messages"]];
			} else {
				dispatch_async(dispatch_get_main_queue(), ^{
					[self processRefPage:refPage];
				});
			}
		}
	});
}

- (void)loginFailed {
	[self completeDownload];
}

- (void)processRefPage:(NSDictionary *)refPage {
	Product *product = (Product *)[moc objectWithID:productObjectID];
	
	[productVersions removeAllObjects];
	[existingReviews removeAllObjects];
	for (Version *version in product.versions) {
		productVersions[version.number] = version;
	}
	
	refPage = refPage[@"data"];
	NSDictionary *versions = refPage[@"versions"];
	for (NSDictionary *v in versions) {
		NSString *identifier = [v[@"id"] stringValue];
		NSString *number = v[@"versionString"];
		Version *version = productVersions[number];
		if (version == nil) {
			version = (Version *)[NSEntityDescription insertNewObjectForEntityForName:@"Version" inManagedObjectContext:moc];
			version.identifier = identifier;
			version.number = number;
			version.product = product;
			productVersions[number] = version;
		} else {
			for (Review *review in version.reviews) {
				existingReviews[review.identifier] = review;
			}
		}
	}
	
	[self fetchReviews];
}

- (void)fetchReviews {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0ul), ^{
		NSString *platform = [_product.platform isEqualToString:kProductPlatformMac] ? kITCReviewAPIPlatformMac : kITCReviewAPIPlatformiOS;
		NSString *reviewsPagePath = [NSString stringWithFormat:kITCReviewAPIReviewsPageAction, _product.productID, platform];
		NSURL *reviewsPageURL = [NSURL URLWithString:[kITCBaseURL stringByAppendingString:reviewsPagePath]];
		NSData *reviewsPageData = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:reviewsPageURL] returningResponse:nil error:nil];
		
		if (reviewsPageData) {
			NSDictionary *reviewsPage = [NSJSONSerialization JSONObjectWithData:reviewsPageData options:0 error:nil];
			NSString *statusCode = reviewsPage[@"statusCode"];
			if (![statusCode isEqualToString:@"SUCCESS"]) {
				[self showAlert:statusCode withMessages:reviewsPage[@"messages"]];
				[self completeDownloadWithStatus:NSLocalizedString(@"Failed", nil)];
			} else {
				dispatch_async(dispatch_get_main_queue(), ^{
					[self processReviewsPage:reviewsPage];
				});
			}
		}
	});
}

- (void)processReviewsPage:(NSDictionary *)reviewsPage {
	[self downloadProgress:(2.0f/3.0f) withStatus:NSLocalizedString(@"Processing reviews...", nil)];
	@synchronized(moc) {
		Product *product = (Product *)[moc objectWithID:productObjectID];
		
		reviewsPage = reviewsPage[@"data"];
		NSArray *reviews = reviewsPage[@"reviews"];
		for (__strong NSDictionary *reviewData in reviews) {
			reviewData = reviewData[@"value"];
			
			NSNumber *identifier = reviewData[@"id"];
			NSTimeInterval timeInterval = [reviewData[@"lastModified"] doubleValue];
			timeInterval /= 1000.0;
			NSDate *lastModified = [NSDate dateWithTimeIntervalSince1970:timeInterval];
			NSString *nickname = reviewData[@"nickname"];
			NSNumber *rating = reviewData[@"rating"];
			NSString *title = reviewData[@"title"];
			NSString *text = reviewData[@"review"];
			NSNumber *helpfulViews = reviewData[@"helpfulViews"];
			NSNumber *totalViews = reviewData[@"totalViews"];
			NSNumber *edited = reviewData[@"edited"];
			NSString *countryCode = reviewData[@"storeFront"];
			NSString *versionNumber = reviewData[@"appVersionString"];
			Version *version = productVersions[versionNumber];
			
			BOOL updateReview = NO;
			Review *review = existingReviews[identifier];
			if (review == nil) {
				review = (Review *)[NSEntityDescription insertNewObjectForEntityForName:@"Review" inManagedObjectContext:moc];
				review.identifier = identifier;
				review.product = product;
				review.countryCode = countryCode;
				updateReview = YES;
			} else if (([lastModified compare:review.lastModified] != NSOrderedSame) ||
					   ![version.identifier isEqualToString:review.version.identifier] ||
					   ![nickname isEqualToString:review.nickname] ||
					   (rating.intValue != review.rating.intValue) ||
					   ![title isEqualToString:review.title] ||
					   ![text isEqualToString:review.text] ||
					   (helpfulViews.intValue != review.helpfulViews.intValue) ||
					   (totalViews.intValue != review.totalViews.intValue) ||
					   (edited.boolValue != review.edited.boolValue)) {
				updateReview = YES;
			}
			if (updateReview) {
				review.lastModified = lastModified;
				review.version = version;
				review.nickname = nickname;
				review.rating = rating;
				review.title = title;
				review.text = text;
				review.helpfulViews = helpfulViews;
				review.totalViews = totalViews;
				review.edited = edited;
				review.unread = @(YES);
				[[version mutableSetValueForKey:@"reviews"] addObject:review];
				[[product mutableSetValueForKey:@"reviews"] addObject:review];
			}
			
			NSDictionary *devResp = reviewData[@"developerResponse"];
			if (devResp != nil) {
				// Developer response was posted.
				NSNumber *identifier = devResp[@"responseId"];
				NSTimeInterval timeInterval = [devResp[@"lastModified"] doubleValue];
				timeInterval /= 1000.0;
				NSDate *lastModified = [NSDate dateWithTimeIntervalSince1970:timeInterval];
				NSString *text = devResp[@"response"];
				NSString *pendingState = devResp[@"pendingState"];
				
				DeveloperResponse *developerResponse = review.developerResponse;
				if (developerResponse == nil) {
					developerResponse = (DeveloperResponse *)[NSEntityDescription insertNewObjectForEntityForName:@"DeveloperResponse" inManagedObjectContext:moc];
					developerResponse.identifier = identifier;
					developerResponse.lastModified = lastModified;
					developerResponse.text = text;
					developerResponse.pendingState = pendingState;
				} else {
					if ([lastModified compare:developerResponse.lastModified] != NSOrderedSame) {
						developerResponse.lastModified = lastModified;
					}
					if (![text isEqualToString:developerResponse.text]) {
						developerResponse.text = text;
					}
					if (![pendingState isEqualToString:developerResponse.pendingState]) {
						developerResponse.pendingState = pendingState;
					}
				}
				developerResponse.review = review;
				review.developerResponse = developerResponse;
			} else {
				// Developer response was deleted.
				DeveloperResponse *developerResponse = review.developerResponse;
				if (developerResponse != nil) {
					[moc deleteObject:developerResponse];
				}
			}
		}
		
		[moc.persistentStoreCoordinator performBlockAndWait:^{
			NSError *saveError = nil;
			[moc save:&saveError];
			if (saveError) {
				NSLog(@"Could not save context: %@", saveError);
			}
		}];
	}
	[self completeDownload];
}

#pragma mark - Helper Methods

- (void)showAlert:(NSString *)title withMessages:(NSDictionary *)messages {
	NSMutableArray *errorMessage = [[NSMutableArray alloc] init];
	for (NSString *type in messages.allKeys) {
		NSArray *message = messages[type];
		if ((message != nil) && ![message isEqual:[NSNull null]]) {
			[errorMessage addObjectsFromArray:message];
		}
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!self.showingAlert) {
			self.showingAlert = YES;
			UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                                     message:[errorMessage componentsJoinedByString:@"\n"]
                                                                              preferredStyle:UIAlertControllerStyleAlert];
			[alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
				self.showingAlert = NO;
			}]];
			[alertController show];
        }
	});
}

- (void)showErrorWithMessage:(NSString *)message {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIAlertController *alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Error", nil)
																				 message:message
																		  preferredStyle:UIAlertControllerStyleAlert];
		[alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
		[alertController show];
	});
}

- (void)downloadProgress:(CGFloat)progress withStatus:(NSString *)status {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (status != nil) {
			_product.account.downloadStatus = status;
		}
		_product.account.downloadProgress = progress;
		self.hud.progress = progress;
	});
}

- (void)completeDownload {
	[self completeDownloadWithStatus:NSLocalizedString(@"Finished", nil)];
}

- (void)completeDownloadWithStatus:(NSString *)status {
	dispatch_async(dispatch_get_main_queue(), ^{
		if ([self.delegate respondsToSelector:@selector(reviewDownloaderDidFinish:)]) {
			[self.delegate reviewDownloaderDidFinish:self];
		}
		[self.hud hide:YES];
		_product.account.downloadStatus = status;
		_product.account.downloadProgress = 1.0f;
		_product.account.isDownloadingReports = NO;
		[UIApplication sharedApplication].idleTimerDisabled = NO;
		if (backgroundTaskID != UIBackgroundTaskInvalid) {
			[[UIApplication sharedApplication] endBackgroundTask:backgroundTaskID];
		}
	});
}

@end
