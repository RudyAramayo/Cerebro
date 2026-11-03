
Amber-HomeFolder/amber/L-10/amber_core_L:	file format elf64-x86-64

Disassembly of section .text:

000000000003a5b0 <lcmCanSender::ModeHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::modeCtrl_t const*)>:
   3a5b0: f3 0f 1e fa                  	endbr64
   3a5b4: 55                           	pushq	%rbp
   3a5b5: 48 89 e5                     	movq	%rsp, %rbp
   3a5b8: 48 83 ec 40                  	subq	$0x40, %rsp
   3a5bc: 48 89 7d d8                  	movq	%rdi, -0x28(%rbp)
   3a5c0: 48 89 75 d0                  	movq	%rsi, -0x30(%rbp)
   3a5c4: 48 89 55 c8                  	movq	%rdx, -0x38(%rbp)
   3a5c8: 48 89 4d c0                  	movq	%rcx, -0x40(%rbp)
   3a5cc: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   3a5d5: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   3a5d9: 31 c0                        	xorl	%eax, %eax
   3a5db: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   3a5df: 0f b6 40 04                  	movzbl	0x4(%rax), %eax
   3a5e3: 88 45 e6                     	movb	%al, -0x1a(%rbp)
   3a5e6: c6 45 e5 20                  	movb	$0x20, -0x1b(%rbp)
   3a5ea: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   3a5ee: 8b 00                        	movl	(%rax), %eax
   3a5f0: 83 c0 10                     	addl	$0x10, %eax
   3a5f3: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   3a5f6: c6 45 e4 02                  	movb	$0x2, -0x1c(%rbp)
   3a5fa: 48 8b 55 e0                  	movq	-0x20(%rbp), %rdx
   3a5fe: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   3a602: 48 89 d7                     	movq	%rdx, %rdi
   3a605: 48 89 c6                     	movq	%rax, %rsi
   3a608: e8 04 f4 ff ff               	callq	0x39a11 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)>
   3a60d: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   3a611: 0f b6 40 04                  	movzbl	0x4(%rax), %eax
   3a615: 3c 04                        	cmpb	$0x4, %al
   3a617: 75 1c                        	jne	0x3a635 <lcmCanSender::ModeHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::modeCtrl_t const*)+0x85>
   3a619: c6 45 e7 00                  	movb	$0x0, -0x19(%rbp)
   3a61d: c6 45 e6 00                  	movb	$0x0, -0x1a(%rbp)
   3a621: c6 45 e5 42                  	movb	$0x42, -0x1b(%rbp)
   3a625: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   3a629: 8b 00                        	movl	(%rax), %eax
   3a62b: 83 c0 10                     	addl	$0x10, %eax
   3a62e: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   3a631: c6 45 e4 03                  	movb	$0x3, -0x1c(%rbp)
   3a635: 90                           	nop
   3a636: 48 8b 45 f8                  	movq	-0x8(%rbp), %rax
   3a63a: 64 48 2b 04 25 28 00 00 00   	subq	%fs:0x28, %rax
   3a643: 74 05                        	je	0x3a64a <lcmCanSender::ModeHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::modeCtrl_t const*)+0x9a>
   3a645: e8 86 69 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   3a64a: c9                           	leave
   3a64b: c3                           	retq

000000000003a64c <lcmCanSender::GripperHandler::~GripperHandler()>:
   3a64c: f3 0f 1e fa                  	endbr64
   3a650: 55                           	pushq	%rbp
   3a651: 48 89 e5                     	movq	%rsp, %rbp
   3a654: 48 89 7d f8                  	movq	%rdi, -0x8(%rbp)
   3a658: 90                           	nop
   3a659: 5d                           	popq	%rbp
   3a65a: c3                           	retq
   3a65b: 90                           	nop

000000000003a65c <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)>:
   3a65c: f3 0f 1e fa                  	endbr64
   3a660: 55                           	pushq	%rbp
   3a661: 48 89 e5                     	movq	%rsp, %rbp
   3a664: 48 83 ec 50                  	subq	$0x50, %rsp
   3a668: 48 89 7d c8                  	movq	%rdi, -0x38(%rbp)
   3a66c: 48 89 75 c0                  	movq	%rsi, -0x40(%rbp)
   3a670: 48 89 55 b8                  	movq	%rdx, -0x48(%rbp)
   3a674: 48 89 4d b0                  	movq	%rcx, -0x50(%rbp)
   3a678: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   3a681: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   3a685: 31 c0                        	xorl	%eax, %eax
   3a687: 48 8b 45 b0                  	movq	-0x50(%rbp), %rax
   3a68b: 0f b6 00                     	movzbl	(%rax), %eax
   3a68e: 0f be c0                     	movsbl	%al, %eax
   3a691: 83 f8 02                     	cmpl	$0x2, %eax
   3a694: 0f 84 98 00 00 00            	je	0x3a732 <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0xd6>
   3a69a: 83 f8 02                     	cmpl	$0x2, %eax
   3a69d: 0f 8f b7 00 00 00            	jg	0x3a75a <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0xfe>
   3a6a3: 85 c0                        	testl	%eax, %eax
   3a6a5: 74 0a                        	je	0x3a6b1 <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0x55>
   3a6a7: 83 f8 01                     	cmpl	$0x1, %eax
   3a6aa: 74 3a                        	je	0x3a6e6 <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0x8a>
   3a6ac: e9 a9 00 00 00               	jmp	0x3a75a <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0xfe>
   3a6b1: c6 45 e5 80                  	movb	$-0x80, -0x1b(%rbp)
   3a6b5: c6 45 e6 00                  	movb	$0x0, -0x1a(%rbp)
   3a6b9: c6 45 e7 00                  	movb	$0x0, -0x19(%rbp)
   3a6bd: c6 45 e8 00                  	movb	$0x0, -0x18(%rbp)
   3a6c1: 8b 05 69 99 0a 00            	movl	0xa9969(%rip), %eax     # 0xe4030 <directControl::GripperNumber>
   3a6c7: 83 c0 10                     	addl	$0x10, %eax
   3a6ca: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   3a6cd: c6 45 e4 04                  	movb	$0x4, -0x1c(%rbp)
   3a6d1: 48 8b 55 e0                  	movq	-0x20(%rbp), %rdx
   3a6d5: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   3a6d9: 48 89 d7                     	movq	%rdx, %rdi
   3a6dc: 48 89 c6                     	movq	%rax, %rsi
   3a6df: e8 2d f3 ff ff               	callq	0x39a11 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)>
   3a6e4: eb 74                        	jmp	0x3a75a <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0xfe>
   3a6e6: c6 45 e5 80                  	movb	$-0x80, -0x1b(%rbp)
   3a6ea: c6 45 e6 01                  	movb	$0x1, -0x1a(%rbp)
   3a6ee: c7 45 dc 00 00 00 00         	movl	$0x0, -0x24(%rbp)
   3a6f5: 48 8b 45 b0                  	movq	-0x50(%rbp), %rax
   3a6f9: 8b 40 04                     	movl	0x4(%rax), %eax
   3a6fc: 89 45 dc                     	movl	%eax, -0x24(%rbp)
   3a6ff: 0f b6 45 dd                  	movzbl	-0x23(%rbp), %eax
   3a703: 88 45 e7                     	movb	%al, -0x19(%rbp)
   3a706: 0f b6 45 dc                  	movzbl	-0x24(%rbp), %eax
   3a70a: 88 45 e8                     	movb	%al, -0x18(%rbp)
   3a70d: 8b 05 1d 99 0a 00            	movl	0xa991d(%rip), %eax     # 0xe4030 <directControl::GripperNumber>
   3a713: 83 c0 10                     	addl	$0x10, %eax
   3a716: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   3a719: c6 45 e4 04                  	movb	$0x4, -0x1c(%rbp)
   3a71d: 48 8b 55 e0                  	movq	-0x20(%rbp), %rdx
   3a721: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   3a725: 48 89 d7                     	movq	%rdx, %rdi
   3a728: 48 89 c6                     	movq	%rax, %rsi
   3a72b: e8 e1 f2 ff ff               	callq	0x39a11 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)>
   3a730: eb 28                        	jmp	0x3a75a <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0xfe>
   3a732: c6 45 e5 81                  	movb	$-0x7f, -0x1b(%rbp)
   3a736: 8b 05 f4 98 0a 00            	movl	0xa98f4(%rip), %eax     # 0xe4030 <directControl::GripperNumber>
   3a73c: 83 c0 10                     	addl	$0x10, %eax
   3a73f: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   3a742: c6 45 e4 01                  	movb	$0x1, -0x1c(%rbp)
   3a746: 48 8b 55 e0                  	movq	-0x20(%rbp), %rdx
   3a74a: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   3a74e: 48 89 d7                     	movq	%rdx, %rdi
   3a751: 48 89 c6                     	movq	%rax, %rsi
   3a754: e8 b8 f2 ff ff               	callq	0x39a11 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)>
   3a759: 90                           	nop
   3a75a: 90                           	nop
   3a75b: 48 8b 45 f8                  	movq	-0x8(%rbp), %rax
   3a75f: 64 48 2b 04 25 28 00 00 00   	subq	%fs:0x28, %rax
   3a768: 74 05                        	je	0x3a76f <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)+0x113>
   3a76a: e8 61 68 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   3a76f: c9                           	leave
   3a770: c3                           	retq
