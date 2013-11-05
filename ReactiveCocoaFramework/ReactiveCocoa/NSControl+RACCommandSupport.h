//
//  NSControl+RACCommandSupport.h
//  ReactiveCocoa
//
//  Created by Josh Abernathy on 3/3/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class RACCommand, RACSignal;

@interface NSControl (RACCommandSupport)

/// Sets the control's command. When the control is clicked, the command is
/// executed with the sender of the event. The control's enabledness is bound
/// to the command's `canExecute`.
///
/// Note: this will reset the control's target and action.
@property (nonatomic, strong) RACCommand *rac_command;

/// A secondary signal whose logical AND with the control's
/// `command.enabled` will determine the control's own `enabled`.
/// The secondary signal must consist of `NSNumber`s wrapping `BOOL`s.
@property (nonatomic, strong) RACSignal * rac_secondaryEnabled;

@end
