//
//  RACRepeatingSignalGenerator.m
//  ReactiveCocoa
//
//  Created by Justin Spahr-Summers on 2013-11-06.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "RACRepeatingSignalGenerator.h"

typedef RACSignal * (^RACRepeatingSignalGeneratorBlock)(id, RACSignalGeneratorBlock);

@interface RACRepeatingSignalGenerator ()

@property (nonatomic, copy, readonly) RACRepeatingSignalGeneratorBlock repeatingBlock;

@end

@implementation RACRepeatingSignalGenerator

#pragma mark Lifecycle

+ (instancetype)repeatingGeneratorWithBlock:(RACRepeatingSignalGeneratorBlock)repeatingBlock {
	NSCParameterAssert(repeatingBlock != nil);

	RACRepeatingSignalGenerator *generator = [[self alloc] init];
	generator->_repeatingBlock = [repeatingBlock copy];
	return generator;
}

#pragma mark RACSignalGenerator

- (RACSignal *)signalWithValue:(id)input {
	return self.block(input, ^(id input) {
		return [self signalWithValue:input];
	});
}

@end
