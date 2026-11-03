
Amber-HomeFolder/amber/L-10/amber_core_L:	file format elf64-x86-64

Disassembly of section .text:

0000000000039a11 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)>:
   39a11: f3 0f 1e fa                  	endbr64
   39a15: 55                           	pushq	%rbp
   39a16: 48 89 e5                     	movq	%rsp, %rbp
   39a19: 48 83 c4 80                  	addq	$-0x80, %rsp
   39a1d: 48 89 f8                     	movq	%rdi, %rax
   39a20: 48 89 f1                     	movq	%rsi, %rcx
   39a23: 48 89 ca                     	movq	%rcx, %rdx
   39a26: 48 89 45 80                  	movq	%rax, -0x80(%rbp)
   39a2a: 48 89 55 88                  	movq	%rdx, -0x78(%rbp)
   39a2e: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   39a37: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   39a3b: 31 c0                        	xorl	%eax, %eax
   39a3d: ba 01 00 00 00               	movl	$0x1, %edx
   39a42: be 03 00 00 00               	movl	$0x3, %esi
   39a47: bf 1d 00 00 00               	movl	$0x1d, %edi
   39a4c: e8 cf 7c fd ff               	callq	0x11720 <.plt.sec+0x930>
   39a51: 89 45 9c                     	movl	%eax, -0x64(%rbp)
   39a54: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39a57: c1 e8 1f                     	shrl	$0x1f, %eax
   39a5a: 84 c0                        	testb	%al, %al
   39a5c: 74 44                        	je	0x39aa2 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x91>
   39a5e: 48 8d 05 26 75 06 00         	leaq	0x67526(%rip), %rax     # 0xa0f8b <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x12b>
   39a65: 48 89 c6                     	movq	%rax, %rsi
   39a68: 48 8d 05 d1 a5 0a 00         	leaq	0xaa5d1(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   39a6f: 48 89 c7                     	movq	%rax, %rdi
   39a72: e8 39 7d fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39a77: 48 8b 15 32 a5 0a 00         	movq	0xaa532(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   39a7e: 48 89 d6                     	movq	%rdx, %rsi
   39a81: 48 89 c7                     	movq	%rax, %rdi
   39a84: e8 e7 7f fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   39a89: 48 8d 05 0d 75 06 00         	leaq	0x6750d(%rip), %rax     # 0xa0f9d <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x13d>
   39a90: 48 89 c7                     	movq	%rax, %rdi
   39a93: e8 c8 7b fd ff               	callq	0x11660 <.plt.sec+0x870>
   39a98: b8 00 00 00 00               	movl	$0x0, %eax
   39a9d: e9 ae 01 00 00               	jmp	0x39c50 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x23f>
   39aa2: 48 8d 05 37 aa 0a 00         	leaq	0xaaa37(%rip), %rax     # 0xe44e0 <canBus::DeviceName[abi:cxx11]>
   39aa9: 48 89 c7                     	movq	%rax, %rdi
   39aac: e8 7f 7a fd ff               	callq	0x11530 <.plt.sec+0x740>
   39ab1: 48 89 c2                     	movq	%rax, %rdx
   39ab4: 48 8d 45 d0                  	leaq	-0x30(%rbp), %rax
   39ab8: 48 89 d6                     	movq	%rdx, %rsi
   39abb: 48 89 c7                     	movq	%rax, %rdi
   39abe: e8 1d 7c fd ff               	callq	0x116e0 <.plt.sec+0x8f0>
   39ac3: 48 8d 55 d0                  	leaq	-0x30(%rbp), %rdx
   39ac7: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39aca: be 33 89 00 00               	movl	$0x8933, %esi           # imm = 0x8933
   39acf: 89 c7                        	movl	%eax, %edi
   39ad1: b8 00 00 00 00               	movl	$0x0, %eax
   39ad6: e8 d5 73 fd ff               	callq	0x10eb0 <.plt.sec+0xc0>
   39adb: 48 8d 45 a0                  	leaq	-0x60(%rbp), %rax
   39adf: ba 18 00 00 00               	movl	$0x18, %edx
   39ae4: be 00 00 00 00               	movl	$0x0, %esi
   39ae9: 48 89 c7                     	movq	%rax, %rdi
   39aec: e8 ef 74 fd ff               	callq	0x10fe0 <.plt.sec+0x1f0>
   39af1: 66 c7 45 a0 1d 00            	movw	$0x1d, -0x60(%rbp)
   39af7: 8b 45 e0                     	movl	-0x20(%rbp), %eax
   39afa: 89 45 a4                     	movl	%eax, -0x5c(%rbp)
   39afd: 48 8d 4d a0                  	leaq	-0x60(%rbp), %rcx
   39b01: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39b04: ba 18 00 00 00               	movl	$0x18, %edx
   39b09: 48 89 ce                     	movq	%rcx, %rsi
   39b0c: 89 c7                        	movl	%eax, %edi
   39b0e: e8 8d 7e fd ff               	callq	0x119a0 <.plt.sec+0xbb0>
   39b13: c1 e8 1f                     	shrl	$0x1f, %eax
   39b16: 84 c0                        	testb	%al, %al
   39b18: 74 44                        	je	0x39b5e <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x14d>
   39b1a: 48 8d 05 83 74 06 00         	leaq	0x67483(%rip), %rax     # 0xa0fa4 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x144>
   39b21: 48 89 c6                     	movq	%rax, %rsi
   39b24: 48 8d 05 15 a5 0a 00         	leaq	0xaa515(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   39b2b: 48 89 c7                     	movq	%rax, %rdi
   39b2e: e8 7d 7c fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39b33: 48 8b 15 76 a4 0a 00         	movq	0xaa476(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   39b3a: 48 89 d6                     	movq	%rdx, %rsi
   39b3d: 48 89 c7                     	movq	%rax, %rdi
   39b40: e8 2b 7f fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   39b45: 48 8d 05 68 74 06 00         	leaq	0x67468(%rip), %rax     # 0xa0fb4 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x154>
   39b4c: 48 89 c7                     	movq	%rax, %rdi
   39b4f: e8 0c 7b fd ff               	callq	0x11660 <.plt.sec+0x870>
   39b54: b8 00 00 00 00               	movl	$0x0, %eax
   39b59: e9 f2 00 00 00               	jmp	0x39c50 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x23f>
   39b5e: 8b 45 80                     	movl	-0x80(%rbp), %eax
   39b61: 89 45 c0                     	movl	%eax, -0x40(%rbp)
   39b64: 0f b6 45 84                  	movzbl	-0x7c(%rbp), %eax
   39b68: 88 45 c4                     	movb	%al, -0x3c(%rbp)
   39b6b: c7 45 98 00 00 00 00         	movl	$0x0, -0x68(%rbp)
   39b72: eb 17                        	jmp	0x39b8b <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x17a>
   39b74: 8b 45 98                     	movl	-0x68(%rbp), %eax
   39b77: 48 98                        	cltq
   39b79: 0f b6 54 05 85               	movzbl	-0x7b(%rbp,%rax), %edx
   39b7e: 8b 45 98                     	movl	-0x68(%rbp), %eax
   39b81: 48 98                        	cltq
   39b83: 88 54 05 c8                  	movb	%dl, -0x38(%rbp,%rax)
   39b87: 83 45 98 01                  	addl	$0x1, -0x68(%rbp)
   39b8b: 0f b6 45 84                  	movzbl	-0x7c(%rbp), %eax
   39b8f: 0f b6 c0                     	movzbl	%al, %eax
   39b92: 39 45 98                     	cmpl	%eax, -0x68(%rbp)
   39b95: 7c dd                        	jl	0x39b74 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x163>
   39b97: 48 8d 4d c0                  	leaq	-0x40(%rbp), %rcx
   39b9b: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39b9e: ba 10 00 00 00               	movl	$0x10, %edx
   39ba3: 48 89 ce                     	movq	%rcx, %rsi
   39ba6: 89 c7                        	movl	%eax, %edi
   39ba8: e8 93 7e fd ff               	callq	0x11a40 <.plt.sec+0xc50>
   39bad: 48 83 f8 10                  	cmpq	$0x10, %rax
   39bb1: 0f 95 c0                     	setne	%al
   39bb4: 84 c0                        	testb	%al, %al
   39bb6: 74 41                        	je	0x39bf9 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x1e8>
   39bb8: 48 8d 05 fa 73 06 00         	leaq	0x673fa(%rip), %rax     # 0xa0fb9 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x159>
   39bbf: 48 89 c6                     	movq	%rax, %rsi
   39bc2: 48 8d 05 77 a4 0a 00         	leaq	0xaa477(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   39bc9: 48 89 c7                     	movq	%rax, %rdi
   39bcc: e8 df 7b fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39bd1: 48 8b 15 d8 a3 0a 00         	movq	0xaa3d8(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   39bd8: 48 89 d6                     	movq	%rdx, %rsi
   39bdb: 48 89 c7                     	movq	%rax, %rdi
   39bde: e8 8d 7e fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   39be3: 48 8d 05 e0 73 06 00         	leaq	0x673e0(%rip), %rax     # 0xa0fca <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x16a>
   39bea: 48 89 c7                     	movq	%rax, %rdi
   39bed: e8 6e 7a fd ff               	callq	0x11660 <.plt.sec+0x870>
   39bf2: b8 00 00 00 00               	movl	$0x0, %eax
   39bf7: eb 57                        	jmp	0x39c50 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x23f>
   39bf9: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39bfc: 89 c7                        	movl	%eax, %edi
   39bfe: e8 ed 79 fd ff               	callq	0x115f0 <.plt.sec+0x800>
   39c03: c1 e8 1f                     	shrl	$0x1f, %eax
   39c06: 84 c0                        	testb	%al, %al
   39c08: 74 41                        	je	0x39c4b <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x23a>
   39c0a: 48 8d 05 bf 73 06 00         	leaq	0x673bf(%rip), %rax     # 0xa0fd0 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x170>
   39c11: 48 89 c6                     	movq	%rax, %rsi
   39c14: 48 8d 05 25 a4 0a 00         	leaq	0xaa425(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   39c1b: 48 89 c7                     	movq	%rax, %rdi
   39c1e: e8 8d 7b fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39c23: 48 8b 15 86 a3 0a 00         	movq	0xaa386(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   39c2a: 48 89 d6                     	movq	%rdx, %rsi
   39c2d: 48 89 c7                     	movq	%rax, %rdi
   39c30: e8 3b 7e fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   39c35: 48 8d 05 a5 73 06 00         	leaq	0x673a5(%rip), %rax     # 0xa0fe1 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x181>
   39c3c: 48 89 c7                     	movq	%rax, %rdi
   39c3f: e8 1c 7a fd ff               	callq	0x11660 <.plt.sec+0x870>
   39c44: b8 00 00 00 00               	movl	$0x0, %eax
   39c49: eb 05                        	jmp	0x39c50 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x23f>
   39c4b: b8 00 00 00 00               	movl	$0x0, %eax
   39c50: 48 8b 55 f8                  	movq	-0x8(%rbp), %rdx
   39c54: 64 48 2b 14 25 28 00 00 00   	subq	%fs:0x28, %rdx
   39c5d: 74 05                        	je	0x39c64 <lcmCanSender::CAN_Send(lcmCanSender::CanFrame_t)+0x253>
   39c5f: e8 6c 73 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   39c64: c9                           	leave
   39c65: c3                           	retq

0000000000039c66 <lcmCanSender::spin(int)>:
   39c66: f3 0f 1e fa                  	endbr64
   39c6a: 55                           	pushq	%rbp
   39c6b: 48 89 e5                     	movq	%rsp, %rbp
   39c6e: 41 57                        	pushq	%r15
   39c70: 41 56                        	pushq	%r14
   39c72: 41 55                        	pushq	%r13
   39c74: 41 54                        	pushq	%r12
   39c76: 53                           	pushq	%rbx
   39c77: 48 81 ec 88 00 00 00         	subq	$0x88, %rsp
   39c7e: 89 bd 5c ff ff ff            	movl	%edi, -0xa4(%rbp)
   39c84: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   39c8d: 48 89 45 c8                  	movq	%rax, -0x38(%rbp)
   39c91: 31 c0                        	xorl	%eax, %eax
   39c93: 8b 85 5c ff ff ff            	movl	-0xa4(%rbp), %eax
   39c99: 89 05 91 a3 0a 00            	movl	%eax, 0xaa391(%rip)     # 0xe4030 <directControl::GripperNumber>
   39c9f: 48 8d 85 6f ff ff ff         	leaq	-0x91(%rbp), %rax
   39ca6: 48 89 c7                     	movq	%rax, %rdi
   39ca9: e8 f2 75 fd ff               	callq	0x112a0 <.plt.sec+0x4b0>
   39cae: 48 8d 95 6f ff ff ff         	leaq	-0x91(%rbp), %rdx
   39cb5: 48 8d 45 a0                  	leaq	-0x60(%rbp), %rax
   39cb9: 48 8d 0d 27 73 06 00         	leaq	0x67327(%rip), %rcx     # 0xa0fe7 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x187>
   39cc0: 48 89 ce                     	movq	%rcx, %rsi
   39cc3: 48 89 c7                     	movq	%rax, %rdi
   39cc6: e8 bd b4 fd ff               	callq	0x15188 <std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>>::basic_string<std::allocator<char>>(char const*, std::allocator<char> const&)>
   39ccb: 48 8d 55 a0                  	leaq	-0x60(%rbp), %rdx
   39ccf: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39cd6: 48 89 d6                     	movq	%rdx, %rsi
   39cd9: 48 89 c7                     	movq	%rax, %rdi
   39cdc: e8 2b 03 00 00               	callq	0x3a00c <lcm::LCM::LCM(std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>>)>
   39ce1: 48 8d 45 a0                  	leaq	-0x60(%rbp), %rax
   39ce5: 48 89 c7                     	movq	%rax, %rdi
   39ce8: e8 f3 70 fd ff               	callq	0x10de0 <snprintf@plt+0xb>
   39ced: 48 8d 85 6f ff ff ff         	leaq	-0x91(%rbp), %rax
   39cf4: 48 89 c7                     	movq	%rax, %rdi
   39cf7: e8 14 71 fd ff               	callq	0x10e10 <.plt.sec+0x20>
   39cfc: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39d03: 48 89 c7                     	movq	%rax, %rdi
   39d06: e8 73 03 00 00               	callq	0x3a07e <lcm::LCM::good() const>
   39d0b: 83 f0 01                     	xorl	$0x1, %eax
   39d0e: 84 c0                        	testb	%al, %al
   39d10: 74 0a                        	je	0x39d1c <lcmCanSender::spin(int)+0xb6>
   39d12: bb 01 00 00 00               	movl	$0x1, %ebx
   39d17: e9 a2 00 00 00               	jmp	0x39dbe <lcmCanSender::spin(int)+0x158>
   39d1c: 4c 8d 35 8d 08 00 00         	leaq	0x88d(%rip), %r14       # 0x3a5b0 <lcmCanSender::ModeHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::modeCtrl_t const*)>
   39d23: 41 bf 00 00 00 00            	movl	$0x0, %r15d
   39d29: 48 8d 95 6e ff ff ff         	leaq	-0x92(%rbp), %rdx
   39d30: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39d37: 49 89 d0                     	movq	%rdx, %r8
   39d3a: 4c 89 f2                     	movq	%r14, %rdx
   39d3d: 4c 89 f9                     	movq	%r15, %rcx
   39d40: 48 8d 35 59 a7 0a 00         	leaq	0xaa759(%rip), %rsi     # 0xe44a0 <lcmNames::SetArmMode[abi:cxx11]>
   39d47: 48 89 c7                     	movq	%rax, %rdi
   39d4a: e8 35 0c 00 00               	callq	0x3a984 <lcm::Subscription* lcm::LCM::subscribe<lcmTypes::modeCtrl_t, lcmCanSender::ModeHandler>(std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, void (lcmCanSender::ModeHandler::*)(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::modeCtrl_t const*), lcmCanSender::ModeHandler*)>
   39d4f: 4c 8d 25 06 09 00 00         	leaq	0x906(%rip), %r12       # 0x3a65c <lcmCanSender::GripperHandler::handleMessage(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*)>
   39d56: 41 bd 00 00 00 00            	movl	$0x0, %r13d
   39d5c: 48 8d 95 6f ff ff ff         	leaq	-0x91(%rbp), %rdx
   39d63: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39d6a: 49 89 d0                     	movq	%rdx, %r8
   39d6d: 4c 89 e2                     	movq	%r12, %rdx
   39d70: 4c 89 e9                     	movq	%r13, %rcx
   39d73: 48 8d 35 46 a7 0a 00         	leaq	0xaa746(%rip), %rsi     # 0xe44c0 <lcmNames::GripperControl[abi:cxx11]>
   39d7a: 48 89 c7                     	movq	%rax, %rdi
   39d7d: e8 b0 0d 00 00               	callq	0x3ab32 <lcm::Subscription* lcm::LCM::subscribe<lcmTypes::gripperCtrl_t, lcmCanSender::GripperHandler>(std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, void (lcmCanSender::GripperHandler::*)(lcm::ReceiveBuffer const*, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char>> const&, lcmTypes::gripperCtrl_t const*), lcmCanSender::GripperHandler*)>
   39d82: 90                           	nop
   39d83: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39d8a: 48 89 c7                     	movq	%rax, %rdi
   39d8d: e8 aa 03 00 00               	callq	0x3a13c <lcm::LCM::handle()>
   39d92: 85 c0                        	testl	%eax, %eax
   39d94: 0f 94 c0                     	sete	%al
   39d97: 84 c0                        	testb	%al, %al
   39d99: 75 e8                        	jne	0x39d83 <lcmCanSender::spin(int)+0x11d>
   39d9b: bb 00 00 00 00               	movl	$0x0, %ebx
   39da0: 48 8d 85 6f ff ff ff         	leaq	-0x91(%rbp), %rax
   39da7: 48 89 c7                     	movq	%rax, %rdi
   39daa: e8 9d 08 00 00               	callq	0x3a64c <lcmCanSender::GripperHandler::~GripperHandler()>
   39daf: 48 8d 85 6e ff ff ff         	leaq	-0x92(%rbp), %rax
   39db6: 48 89 c7                     	movq	%rax, %rdi
   39db9: e8 e2 07 00 00               	callq	0x3a5a0 <lcmCanSender::ModeHandler::~ModeHandler()>
   39dbe: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39dc5: 48 89 c7                     	movq	%rax, %rdi
   39dc8: e8 cd 02 00 00               	callq	0x3a09a <lcm::LCM::~LCM()>
   39dcd: 89 d8                        	movl	%ebx, %eax
   39dcf: 48 8b 55 c8                  	movq	-0x38(%rbp), %rdx
   39dd3: 64 48 2b 14 25 28 00 00 00   	subq	%fs:0x28, %rdx
   39ddc: 74 7c                        	je	0x39e5a <lcmCanSender::spin(int)+0x1f4>
   39dde: eb 75                        	jmp	0x39e55 <lcmCanSender::spin(int)+0x1ef>
   39de0: f3 0f 1e fa                  	endbr64
   39de4: 48 89 c3                     	movq	%rax, %rbx
   39de7: 48 8d 45 a0                  	leaq	-0x60(%rbp), %rax
   39deb: 48 89 c7                     	movq	%rax, %rdi
   39dee: e8 ed 6f fd ff               	callq	0x10de0 <snprintf@plt+0xb>
   39df3: eb 07                        	jmp	0x39dfc <lcmCanSender::spin(int)+0x196>
   39df5: f3 0f 1e fa                  	endbr64
   39df9: 48 89 c3                     	movq	%rax, %rbx
   39dfc: 48 8d 85 6f ff ff ff         	leaq	-0x91(%rbp), %rax
   39e03: 48 89 c7                     	movq	%rax, %rdi
   39e06: e8 05 70 fd ff               	callq	0x10e10 <.plt.sec+0x20>
   39e0b: 48 89 d8                     	movq	%rbx, %rax
   39e0e: 48 89 c7                     	movq	%rax, %rdi
   39e11: e8 5a 73 fd ff               	callq	0x11170 <.plt.sec+0x380>
   39e16: f3 0f 1e fa                  	endbr64
   39e1a: 48 89 c3                     	movq	%rax, %rbx
   39e1d: 48 8d 85 6f ff ff ff         	leaq	-0x91(%rbp), %rax
   39e24: 48 89 c7                     	movq	%rax, %rdi
   39e27: e8 20 08 00 00               	callq	0x3a64c <lcmCanSender::GripperHandler::~GripperHandler()>
   39e2c: 48 8d 85 6e ff ff ff         	leaq	-0x92(%rbp), %rax
   39e33: 48 89 c7                     	movq	%rax, %rdi
   39e36: e8 65 07 00 00               	callq	0x3a5a0 <lcmCanSender::ModeHandler::~ModeHandler()>
   39e3b: 48 8d 85 70 ff ff ff         	leaq	-0x90(%rbp), %rax
   39e42: 48 89 c7                     	movq	%rax, %rdi
   39e45: e8 50 02 00 00               	callq	0x3a09a <lcm::LCM::~LCM()>
   39e4a: 48 89 d8                     	movq	%rbx, %rax
   39e4d: 48 89 c7                     	movq	%rax, %rdi
   39e50: e8 1b 73 fd ff               	callq	0x11170 <.plt.sec+0x380>
   39e55: e8 76 71 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   39e5a: 48 81 c4 88 00 00 00         	addq	$0x88, %rsp
   39e61: 5b                           	popq	%rbx
   39e62: 41 5c                        	popq	%r12
   39e64: 41 5d                        	popq	%r13
   39e66: 41 5e                        	popq	%r14
   39e68: 41 5f                        	popq	%r15
   39e6a: 5d                           	popq	%rbp
   39e6b: c3                           	retq
