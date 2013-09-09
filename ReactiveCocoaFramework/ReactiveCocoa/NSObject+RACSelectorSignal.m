//
//  NSObject+RACSelectorSignal.m
//  ReactiveCocoa
//
//  Created by Josh Abernathy on 3/18/13.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "NSObject+RACSelectorSignal.h"
#import "EXTScope.h"
#import "NSInvocation+RACTypeParsing.h"
#import "NSObject+RACDeallocating.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACObjCRuntime.h"
#import "RACSubject.h"
#import "RACTuple.h"
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const RACSelectorSignalErrorDomain = @"RACSelectorSignalErrorDomain";
const NSInteger RACSelectorSignalErrorMethodSwizzlingRace = 1;

static NSString * const RACSignalForSelectorAliasPrefix = @"rac_alias_";
static NSString * const RACClassSuffix = @"_RACSelectorSignal";

#if 0
static NSMutableSet *swizzledClasses() {
	static NSMutableSet *set;
	static dispatch_once_t pred;
	
	dispatch_once(&pred, ^{
		set = [[NSMutableSet alloc] init];
	});

	return set;
}
#endif

@implementation NSObject (RACSelectorSignal)

static BOOL RACForwardInvocation(id self, NSInvocation *invocation) {
	SEL aliasSelector = RACAliasForSelector(invocation.selector);
	RACSubject *subject = objc_getAssociatedObject(self, aliasSelector);

	Class class = object_getClass(invocation.target);
	BOOL respondsToAlias = [class instancesRespondToSelector:aliasSelector];
	if (respondsToAlias) {
		invocation.selector = aliasSelector;
		[invocation invoke];
	}

	if (subject == nil) return respondsToAlias;

	[subject sendNext:invocation.rac_argumentsTuple];
	return YES;
}

static void RACSwizzleForwardInvocation(Class class) {
	SEL forwardInvocationSEL = @selector(forwardInvocation:);
	SEL methodSignatureSEL = @selector(methodSignatureForSelector:);
	Method forwardInvocationMethod = class_getInstanceMethod(class, forwardInvocationSEL);
	Method methodSignatureMethod = class_getInstanceMethod(class, methodSignatureSEL);

	// Preserve any existing implementation of -forwardInvocation:.
	void (*originalForwardInvocation)(id, SEL, NSInvocation *) = NULL;
	if (forwardInvocationMethod != NULL) {
		originalForwardInvocation = (__typeof__(originalForwardInvocation))method_getImplementation(forwardInvocationMethod);
	}

	// Set up a new version of -forwardInvocation:.
	//
	// If the selector has been passed to -rac_signalForSelector:, invoke
	// the aliased method, and forward the arguments to any attached signals.
	//
	// If the selector has not been passed to -rac_signalForSelector:,
	// invoke any existing implementation of -forwardInvocation:. If there
	// was no existing implementation, throw an unrecognized selector
	// exception.
	id newForwardInvocation = ^(id self, NSInvocation *invocation) {
		BOOL matched = RACForwardInvocation(self, invocation);
		if (matched) return;

		if (originalForwardInvocation == NULL) {
			[self doesNotRecognizeSelector:invocation.selector];
		} else {
			originalForwardInvocation(self, forwardInvocationSEL, invocation);
		}
	};

	class_replaceMethod(class, forwardInvocationSEL, imp_implementationWithBlock(newForwardInvocation), "v@:@");

	// Preserve any existing implementation of -methodSignatureForSelector:.
	NSMethodSignature * (*originalMethodSignature)(id, SEL, SEL) = (__typeof__(originalMethodSignature))method_getImplementation(methodSignatureMethod);

	// Set up a new version of -methodSignatureForSelector:.
	id newMethodSignature = ^(id self, SEL selector) {
		SEL aliasSelector = RACAliasForSelector(selector);
		NSMethodSignature *signature = originalMethodSignature(self, methodSignatureSEL, aliasSelector);
		if (signature != nil) return signature;

		signature = originalMethodSignature(self, methodSignatureSEL, selector);
		if (signature != nil) return signature;

		const char *typeEncoding = RACSignatureForUndefinedSelector(selector);
		return [NSMethodSignature signatureWithObjCTypes:typeEncoding];
	};

	class_replaceMethod(class, methodSignatureSEL, imp_implementationWithBlock(newMethodSignature), "@@::");
}

static RACSignal *NSObjectRACSignalForSelector(NSObject *self, SEL selector, Protocol *protocol) {
	SEL aliasSelector = RACAliasForSelector(selector);

	@synchronized (self) {
		RACSubject *subject = objc_getAssociatedObject(self, aliasSelector);
		if (subject != nil) return subject;

		Class class = RACSwizzleClass(self, selector);
		NSCAssert(class != nil, @"Could not swizzle class of %@", self);

		subject = [RACSubject subject];
		objc_setAssociatedObject(self, aliasSelector, subject, OBJC_ASSOCIATION_RETAIN);

		[self.rac_deallocDisposable addDisposable:[RACDisposable disposableWithBlock:^{
			[subject sendCompleted];
		}]];

		Method targetMethod = class_getInstanceMethod(class, selector);
		if (targetMethod == NULL) {
			#if 0
			const char *typeEncoding;
			if (protocol == NULL) {
				typeEncoding = RACSignatureForUndefinedSelector(selector);
			} else {
				// Look for the selector as an optional instance method.
				struct objc_method_description methodDescription = protocol_getMethodDescription(protocol, selector, NO, YES);

				if (methodDescription.name == NULL) {
					// Then fall back to looking for a required instance
					// method.
					methodDescription = protocol_getMethodDescription(protocol, selector, YES, YES);
					NSCAssert(methodDescription.name != NULL, @"Selector %@ does not exist in <%s>", NSStringFromSelector(selector), protocol_getName(protocol));
				}

				typeEncoding = methodDescription.types;
			}

			// Define the selector to call -forwardInvocation:.
			if (!class_addMethod(class, selector, _objc_msgForward, typeEncoding)) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"A race condition occurred implementing %@ on class %@", nil), NSStringFromSelector(selector), class],
					NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"Invoke -rac_signalForSelector: again to override the implementation.", nil)
				};

				return [RACSignal error:[NSError errorWithDomain:RACSelectorSignalErrorDomain code:RACSelectorSignalErrorMethodSwizzlingRace userInfo:userInfo]];
			}
			#endif
		} else if (method_getImplementation(targetMethod) != _objc_msgForward) {
			NSLog(@"### METHOD %s ALREADY EXISTS on %@", sel_getName(method_getName(targetMethod)), class);

			// Make a method alias for the existing method implementation.
			BOOL addedAlias __attribute__((unused)) = class_addMethod(class, aliasSelector, method_getImplementation(targetMethod), method_getTypeEncoding(targetMethod));
			NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), class);

			// Redefine the selector to call -forwardInvocation:.
			class_replaceMethod(class, selector, _objc_msgForward, method_getTypeEncoding(targetMethod));
		}

		return subject;
	}
}

static SEL RACAliasForSelector(SEL originalSelector) {
	NSString *selectorName = NSStringFromSelector(originalSelector);
	return NSSelectorFromString([RACSignalForSelectorAliasPrefix stringByAppendingString:selectorName]);
}

static const char *RACSignatureForUndefinedSelector(SEL selector) {
	const char *name = sel_getName(selector);
	NSMutableString *signature = [NSMutableString stringWithString:@"v@:"];

	while ((name = strchr(name, ':')) != NULL) {
		[signature appendString:@"@"];
		name++;
	}

	return signature.UTF8String;
}

static Class RACSwizzleClass(NSObject *self, SEL skipSelector) {
//	Class statedClass = self.class;
	Class baseClass = object_getClass(self);
	NSString *className = NSStringFromClass(baseClass);

	#if 0
	if ([className hasSuffix:RACClassSuffix]) {
		return baseClass;
	} else if (statedClass != baseClass) {
		// If the class is already lying about what it is, it's probably a KVO
		// dynamic subclass or something else that we shouldn't touch
		// ourselves.
		//
		// Just swizzle -forwardInvocation: in-place. Since the object's class
		// was almost certainly dynamically changed, we shouldn't see another of
		// these classes in the hierarchy.
		@synchronized (swizzledClasses()) {
			if (![swizzledClasses() containsObject:className]) {
				RACSwizzleForwardInvocation(baseClass);
				[swizzledClasses() addObject:className];
			}
		}

		return baseClass;
	}
	#endif

	NSString *dupClassName = className;
	Class dupClass;

	do {
		dupClassName = [dupClassName stringByAppendingString:RACClassSuffix];
		dupClass = objc_getClass(dupClassName.UTF8String);
	} while (dupClass != nil);

	dupClass = [RACObjCRuntime createClass:dupClassName.UTF8String inheritingFromClass:nil];
	if (dupClass == nil) return nil;

	RACDuplicateClassAndSuperclasses(baseClass, dupClass, skipSelector);
	RACSwizzleForwardInvocation(dupClass);
	objc_registerClassPair(dupClass);

	//NSCAssert(class_getInstanceSize(dupClass) == class_getInstanceSize(baseClass), @"Duplicated class %@ size (%zu) does not equal original %@ size (%zu)", dupClass, class_getInstanceSize(dupClass), baseClass, class_getInstanceSize(baseClass));

	object_setClass(self, dupClass);
	return dupClass;
}

static void RACDuplicateClassAndSuperclasses(Class originalClass, Class targetClass, SEL skipSelector) {
	NSCParameterAssert(originalClass != nil);
	NSCParameterAssert(targetClass != nil);
	NSCParameterAssert(skipSelector != NULL);

	// Copy superclass definitions first.
	Class superclass = class_getSuperclass(originalClass);
	if (superclass != nil) RACDuplicateClassAndSuperclasses(superclass, targetClass, skipSelector);

	unsigned ivarCount = 0;
	Ivar *ivars = class_copyIvarList(originalClass, &ivarCount);
	@onExit {
		free(ivars);
	};

	for (unsigned i = 0; i < ivarCount; i++) {
		NSUInteger size = 0;
		NSUInteger align = 0;
		NSGetSizeAndAlignment(ivar_getTypeEncoding(ivars[i]), &size, &align);

		class_addIvar(targetClass, ivar_getName(ivars[i]), size, (uint8_t)align, ivar_getTypeEncoding(ivars[i]));
	}

	unsigned protoCount = 0;
	Protocol * __unsafe_unretained *protos = class_copyProtocolList(originalClass, &protoCount);
	@onExit {
		free(protos);
	};

	for (unsigned i = 0; i < protoCount; i++) {
		class_addProtocol(targetClass, protos[i]);
	}

	RACDuplicateMethods(originalClass, targetClass, skipSelector);
	RACDuplicateMethods(object_getClass(originalClass), object_getClass(targetClass), NULL);
}

static void RACDuplicateMethods(Class originalClass, Class targetClass, SEL skipSelector) {
	NSCParameterAssert(originalClass != nil);
	NSCParameterAssert(targetClass != nil);

	unsigned methodCount = 0;
	Method *methods = class_copyMethodList(originalClass, &methodCount);
	@onExit {
		free(methods);
	};

	for (unsigned i = 0; i < methodCount; i++) {
		SEL name = method_getName(methods[i]);
		if (name == skipSelector) {
			class_addMethod(targetClass, RACAliasForSelector(name), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
		} else {
			class_addMethod(targetClass, name, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
		}
	}
}

- (RACSignal *)rac_signalForSelector:(SEL)selector {
	NSCParameterAssert(selector != NULL);

	return NSObjectRACSignalForSelector(self, selector, NULL);
}

- (RACSignal *)rac_signalForSelector:(SEL)selector fromProtocol:(Protocol *)protocol {
	NSCParameterAssert(selector != NULL);
	NSCParameterAssert(protocol != NULL);

	return NSObjectRACSignalForSelector(self, selector, protocol);
}

@end
