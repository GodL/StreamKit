//
//  NSObject+SKSelectorSignal.m
//  StreamKitDemo
//
//  Created by 李浩 on 2018/6/24.
//  Copyright © 2018年 李浩. All rights reserved.
//

#import "NSObject+SKSelectorSignal.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "SKSubject.h"
#import "NSObject+SKDeallocating.h"
#import "SKCompoundDisposable.h"
#import "NSObject+SKDelegateProxy.h"
#import "SKDelegateProxy.h"

static const void * SKSubclassAssociationKey = &SKSubclassAssociationKey;

static NSString *const SKSignalForSelectorAliasPrefix = @"sk_alias_";

static NSString *const SKSubclassSuffix = @"_SKSelectorSignalClass";

static SEL SKAliasSelectorWithSelector(SEL sel) {
    NSString *alias_name = [[NSString alloc] initWithUTF8String:sel_getName(sel)];
    NSCParameterAssert(alias_name);
    return sel_registerName([SKSignalForSelectorAliasPrefix stringByAppendingString:alias_name].UTF8String);
}

static NSMutableSet *swizzleClasses() {
    static NSMutableSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static BOOL ForwardInvocation(NSInvocation *invocation) {
    return YES;
}

static void SKSwizzleDelegateMethod(Class cls) {
    static NSMutableSet *deleteClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        deleteClasses = [NSMutableSet set];
    });
}

static void SKSwizzleForwardInvocation(Class cls) {
    SEL invocationSel = sel_registerName("forwardInvocation:");
    Method invocationMethod = class_getInstanceMethod(cls, invocationSel);
    void (*originInvocation)(__unsafe_unretained id,SEL,NSInvocation *) = NULL;
    IMP newInvocation = imp_implementationWithBlock(^ (__unsafe_unretained id self,SEL sel,NSInvocation *invocation) {
        BOOL math = ForwardInvocation(invocation);
        if (math) return ;
        if (originInvocation == NULL) {
            [self doesNotRecognizeSelector:invocationSel];
        }else {
            originInvocation(self,sel,invocation);
        }
    });
    if (!class_addMethod(cls, invocationSel, newInvocation, method_getTypeEncoding(invocationMethod))) {
        originInvocation = (__typeof__(originInvocation))method_getImplementation(invocationMethod);
        originInvocation = (__typeof__(originInvocation))method_setImplementation(invocationMethod, newInvocation);
    }
}

static void SKSwizzleRespondsToSelector(Class cls) {
    SEL selector = @selector(respondsToSelector:);
    Method selectorMethod = class_getInstanceMethod(cls, selector);
    BOOL (*originImplmentation)(id,SEL,SEL) = NULL;
    id newImplmentation = ^ (id self,SEL respondsSelector) {
        Method method = class_getInstanceMethod(object_getClass(self), respondsSelector);
        if (method != NULL && method_getImplementation(method) == _objc_msgForward) {
            SEL aliasSelector = SKAliasSelectorWithSelector(respondsSelector);
            if ( objc_getAssociatedObject(self, aliasSelector) != NULL) return YES;
        }
        return originImplmentation(self,selector,respondsSelector);
    };
    if (!class_addMethod(cls, selector, imp_implementationWithBlock(newImplmentation), method_getTypeEncoding(selectorMethod))) {
        originImplmentation = (__typeof__(originImplmentation))method_getImplementation(selectorMethod);
        originImplmentation = (__typeof__(originImplmentation))method_setImplementation(selectorMethod, imp_implementationWithBlock(newImplmentation));
    }
}

static void SKSwizzleGetClass(Class base,Class stated) {
    SEL selector = @selector(class);
    Method method = class_getInstanceMethod(base, selector);
    IMP new = imp_implementationWithBlock(^ (id self) {
        return stated;
    });
    class_replaceMethod(base, selector, new, method_getTypeEncoding(method));
}

static void SKSwizzleDelegate(Class cls, __unsafe_unretained SKDelegateProxy *proxy) {
    if (proxy == nil) return;
    SEL delegateSelector = @selector(setDelegate:);
    Method delegateMethod = class_getInstanceMethod(cls, delegateSelector);
    if (delegateMethod == NULL) return;
    void (*originImplmentation)(__unsafe_unretained id,SEL selector,__unsafe_unretained id) = NULL;
    IMP newIMP = imp_implementationWithBlock(^ (__unsafe_unretained id self,__unsafe_unretained id delegate){
        proxy.realDelegate = delegate;
        if (originImplmentation != NULL) {
            originImplmentation(self,delegateSelector,proxy);
        }else {
            struct objc_super super_objc = {
                .receiver = self,
                .super_class = class_getSuperclass(cls)
            };
            ((void(*)(void *,SEL,id))objc_msgSendSuper)(&super_objc,delegateSelector,proxy);
        }
    });
    if (!class_addMethod(cls, delegateSelector, newIMP, method_getTypeEncoding(delegateMethod))) {
        originImplmentation = (__typeof__(originImplmentation))method_getImplementation(delegateMethod);
        originImplmentation = (__typeof__(originImplmentation))method_setImplementation(delegateMethod, newIMP);
    }
}

static Class SKSwizzleClass(NSObject *self) {
    Class statedClass = self.class;
    Class baseClass = object_getClass(self);
    Class knowClass = objc_getAssociatedObject(self, SKSubclassAssociationKey);
    if (knowClass != NULL) return knowClass;
    if (statedClass != baseClass) {
        NSMutableSet *classes = swizzleClasses();
        @synchronized (classes) {
            if (![classes containsObject:baseClass]) {
                SKSwizzleForwardInvocation(baseClass);
                SKSwizzleRespondsToSelector(baseClass);
                SKSwizzleDelegate(baseClass, self.sk_delegateProxy);
                [classes addObject:baseClass];
            }
        }
        return baseClass;
    }
    NSString *className = NSStringFromClass(baseClass);
    const char *subClassName = [className stringByAppendingString:SKSubclassSuffix].UTF8String;
    Class subClass = objc_getClass(subClassName);
    if (subClass == nil) {
        subClass = objc_allocateClassPair(baseClass, subClassName, 0);
        if (subClass == nil) return nil;
        SKSwizzleForwardInvocation(subClass);
        SKSwizzleRespondsToSelector(subClass);
        SKSwizzleGetClass(subClass, statedClass);
        SKSwizzleDelegate(subClass, self.sk_delegateProxy);
        objc_registerClassPair(subClass);
    }
    object_setClass(self, subClass);
    objc_setAssociatedObject(self, SKSubclassAssociationKey, subClass, OBJC_ASSOCIATION_ASSIGN);
    return subClass;
}

@implementation NSObject (SKSelectorSignal)

- (SKSignal *)sk_signalForSelector:(SEL)selector {
    SEL aliasSeletor = SKAliasSelectorWithSelector(selector);
    @synchronized (self) {
        SKSubject *subject = objc_getAssociatedObject(self, aliasSeletor);
        if (subject) return subject;
        Class class = SKSwizzleClass(self);
        subject = [SKSubject subject];
        objc_setAssociatedObject(self, aliasSeletor, subject, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.deallocDisposable addDisposable:[SKDisposable disposableWithBlock:^{
            [subject sendCompleted];
        }]];
        
        Method targetMethod = class_getInstanceMethod(class, selector);
        if (targetMethod == NULL) {
            Protocol *protocol = self.sk_delegateProxy.protocol;
            if (protocol) {
                struct objc_method_description description = protocol_getMethodDescription(protocol, selector, NO, YES);
                if (description.name == NULL) {
                    description = protocol_getMethodDescription(protocol, selector, YES, YES);
                }
            }
            
        }
    }
}

@end
