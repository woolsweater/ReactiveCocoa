//
//  RACRepeatingSignalGenerator.h
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2013-11-06.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "RACSignalGenerator.h"

/// 
@interface RACRepeatingSignalGenerator : RACSignalGenerator

/// 
+ (instancetype)repeatingGeneratorWithBlock:(RACSignal * (^)(id input, RACSignalGeneratorBlock generateNext))repeatingBlock;

@end
