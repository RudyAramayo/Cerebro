//
//  ROBConsciousness.m
//  Cerebro
//
//  Created by Rob Makina on 5/11/18.
//  Copyright © 2018 Rob Makina. All rights reserved.
//

#import "ROBConsciousness.h"

@implementation ROBConsciousness
//This command starts up the cakechat server
//"cd /Users/rob/Desktop/cakechat/bin && gunicorn cakechat_server:app -w 1 -b 192.168.0.34:8080 --timeout 2000"
//THis command works... the one above failed during intermittent upgrades
//"cd /Users/rob/Desktop/cakechat/bin && /Users/rob/anaconda3/bin/python cakechat_server.py -b 127.0.0.1:8080"

-(id)init{
    self = [super init];
    
    if (self) {
        
    }
    
    return self;
}


- (void) initializeConsiousness
{
    NSLog(@"init Mind");
    //If the mind has been booted we can recieve some feed back from the brain server at
    //127.0.0.1:8080
    
}

@end
