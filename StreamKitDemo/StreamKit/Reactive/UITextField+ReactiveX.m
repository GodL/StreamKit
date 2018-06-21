//
//  UITextField+ReactiveX.m
//  StreamKitDemo
//
//  Created by 李浩 on 2017/4/7.
//  Copyright © 2017年 李浩. All rights reserved.
//

#import "UITextField+ReactiveX.h"
#import "UIControl+ReactiveX.h"
#import "SKSignal+Operations.h"
#import "SKObjectifyMarco.h"
#import "SKSubscriber.h"

@implementation UITextField (ReactiveX)

- (SKSignal*)sk_textSignal {
    @weakify(self)
    return [[SKSignal defer:^SKSignal *{
        @strongify(self)
        return [SKSignal return:self];
    }] concat:[self sk_signalForControlEvents:UIControlEventAllEditingEvents]];
}

@end
