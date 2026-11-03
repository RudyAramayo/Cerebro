
Amber-HomeFolder/amber/L-10/amber_core_L:	file format elf64-x86-64

Disassembly of section .text:

0000000000039283 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)>:
   39283: f3 0f 1e fa                  	endbr64
   39287: 55                           	pushq	%rbp
   39288: 48 89 e5                     	movq	%rsp, %rbp
   3928b: 48 83 c4 80                  	addq	$-0x80, %rsp
   3928f: 48 89 f8                     	movq	%rdi, %rax
   39292: 48 89 f1                     	movq	%rsi, %rcx
   39295: 48 89 ca                     	movq	%rcx, %rdx
   39298: 48 89 45 80                  	movq	%rax, -0x80(%rbp)
   3929c: 48 89 55 88                  	movq	%rdx, -0x78(%rbp)
   392a0: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   392a9: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   392ad: 31 c0                        	xorl	%eax, %eax
   392af: ba 01 00 00 00               	movl	$0x1, %edx
   392b4: be 03 00 00 00               	movl	$0x3, %esi
   392b9: bf 1d 00 00 00               	movl	$0x1d, %edi
   392be: e8 5d 84 fd ff               	callq	0x11720 <.plt.sec+0x930>
   392c3: 89 45 9c                     	movl	%eax, -0x64(%rbp)
   392c6: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   392c9: c1 e8 1f                     	shrl	$0x1f, %eax
   392cc: 84 c0                        	testb	%al, %al
   392ce: 74 44                        	je	0x39314 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x91>
   392d0: 48 8d 05 f9 7b 06 00         	leaq	0x67bf9(%rip), %rax     # 0xa0ed0 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x70>
   392d7: 48 89 c6                     	movq	%rax, %rsi
   392da: 48 8d 05 5f ad 0a 00         	leaq	0xaad5f(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   392e1: 48 89 c7                     	movq	%rax, %rdi
   392e4: e8 c7 84 fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   392e9: 48 8b 15 c0 ac 0a 00         	movq	0xaacc0(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   392f0: 48 89 d6                     	movq	%rdx, %rsi
   392f3: 48 89 c7                     	movq	%rax, %rdi
   392f6: e8 75 87 fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   392fb: 48 8d 05 e3 7b 06 00         	leaq	0x67be3(%rip), %rax     # 0xa0ee5 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x85>
   39302: 48 89 c7                     	movq	%rax, %rdi
   39305: e8 56 83 fd ff               	callq	0x11660 <.plt.sec+0x870>
   3930a: b8 00 00 00 00               	movl	$0x0, %eax
   3930f: e9 ae 01 00 00               	jmp	0x394c2 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x23f>
   39314: 48 8d 05 c5 b1 0a 00         	leaq	0xab1c5(%rip), %rax     # 0xe44e0 <canBus::DeviceName[abi:cxx11]>
   3931b: 48 89 c7                     	movq	%rax, %rdi
   3931e: e8 0d 82 fd ff               	callq	0x11530 <.plt.sec+0x740>
   39323: 48 89 c2                     	movq	%rax, %rdx
   39326: 48 8d 45 d0                  	leaq	-0x30(%rbp), %rax
   3932a: 48 89 d6                     	movq	%rdx, %rsi
   3932d: 48 89 c7                     	movq	%rax, %rdi
   39330: e8 ab 83 fd ff               	callq	0x116e0 <.plt.sec+0x8f0>
   39335: 48 8d 55 d0                  	leaq	-0x30(%rbp), %rdx
   39339: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   3933c: be 33 89 00 00               	movl	$0x8933, %esi           # imm = 0x8933
   39341: 89 c7                        	movl	%eax, %edi
   39343: b8 00 00 00 00               	movl	$0x0, %eax
   39348: e8 63 7b fd ff               	callq	0x10eb0 <.plt.sec+0xc0>
   3934d: 48 8d 45 a0                  	leaq	-0x60(%rbp), %rax
   39351: ba 18 00 00 00               	movl	$0x18, %edx
   39356: be 00 00 00 00               	movl	$0x0, %esi
   3935b: 48 89 c7                     	movq	%rax, %rdi
   3935e: e8 7d 7c fd ff               	callq	0x10fe0 <.plt.sec+0x1f0>
   39363: 66 c7 45 a0 1d 00            	movw	$0x1d, -0x60(%rbp)
   39369: 8b 45 e0                     	movl	-0x20(%rbp), %eax
   3936c: 89 45 a4                     	movl	%eax, -0x5c(%rbp)
   3936f: 48 8d 4d a0                  	leaq	-0x60(%rbp), %rcx
   39373: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39376: ba 18 00 00 00               	movl	$0x18, %edx
   3937b: 48 89 ce                     	movq	%rcx, %rsi
   3937e: 89 c7                        	movl	%eax, %edi
   39380: e8 1b 86 fd ff               	callq	0x119a0 <.plt.sec+0xbb0>
   39385: c1 e8 1f                     	shrl	$0x1f, %eax
   39388: 84 c0                        	testb	%al, %al
   3938a: 74 44                        	je	0x393d0 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x14d>
   3938c: 48 8d 05 59 7b 06 00         	leaq	0x67b59(%rip), %rax     # 0xa0eec <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x8c>
   39393: 48 89 c6                     	movq	%rax, %rsi
   39396: 48 8d 05 a3 ac 0a 00         	leaq	0xaaca3(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   3939d: 48 89 c7                     	movq	%rax, %rdi
   393a0: e8 0b 84 fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   393a5: 48 8b 15 04 ac 0a 00         	movq	0xaac04(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   393ac: 48 89 d6                     	movq	%rdx, %rsi
   393af: 48 89 c7                     	movq	%rax, %rdi
   393b2: e8 b9 86 fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   393b7: 48 8d 05 3e 7b 06 00         	leaq	0x67b3e(%rip), %rax     # 0xa0efc <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x9c>
   393be: 48 89 c7                     	movq	%rax, %rdi
   393c1: e8 9a 82 fd ff               	callq	0x11660 <.plt.sec+0x870>
   393c6: b8 00 00 00 00               	movl	$0x0, %eax
   393cb: e9 f2 00 00 00               	jmp	0x394c2 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x23f>
   393d0: 8b 45 80                     	movl	-0x80(%rbp), %eax
   393d3: 89 45 c0                     	movl	%eax, -0x40(%rbp)
   393d6: 0f b6 45 84                  	movzbl	-0x7c(%rbp), %eax
   393da: 88 45 c4                     	movb	%al, -0x3c(%rbp)
   393dd: c7 45 98 00 00 00 00         	movl	$0x0, -0x68(%rbp)
   393e4: eb 17                        	jmp	0x393fd <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x17a>
   393e6: 8b 45 98                     	movl	-0x68(%rbp), %eax
   393e9: 48 98                        	cltq
   393eb: 0f b6 54 05 85               	movzbl	-0x7b(%rbp,%rax), %edx
   393f0: 8b 45 98                     	movl	-0x68(%rbp), %eax
   393f3: 48 98                        	cltq
   393f5: 88 54 05 c8                  	movb	%dl, -0x38(%rbp,%rax)
   393f9: 83 45 98 01                  	addl	$0x1, -0x68(%rbp)
   393fd: 0f b6 45 84                  	movzbl	-0x7c(%rbp), %eax
   39401: 0f b6 c0                     	movzbl	%al, %eax
   39404: 39 45 98                     	cmpl	%eax, -0x68(%rbp)
   39407: 7c dd                        	jl	0x393e6 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x163>
   39409: 48 8d 4d c0                  	leaq	-0x40(%rbp), %rcx
   3940d: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   39410: ba 10 00 00 00               	movl	$0x10, %edx
   39415: 48 89 ce                     	movq	%rcx, %rsi
   39418: 89 c7                        	movl	%eax, %edi
   3941a: e8 21 86 fd ff               	callq	0x11a40 <.plt.sec+0xc50>
   3941f: 48 83 f8 10                  	cmpq	$0x10, %rax
   39423: 0f 95 c0                     	setne	%al
   39426: 84 c0                        	testb	%al, %al
   39428: 74 41                        	je	0x3946b <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x1e8>
   3942a: 48 8d 05 d0 7a 06 00         	leaq	0x67ad0(%rip), %rax     # 0xa0f01 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0xa1>
   39431: 48 89 c6                     	movq	%rax, %rsi
   39434: 48 8d 05 05 ac 0a 00         	leaq	0xaac05(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   3943b: 48 89 c7                     	movq	%rax, %rdi
   3943e: e8 6d 83 fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39443: 48 8b 15 66 ab 0a 00         	movq	0xaab66(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   3944a: 48 89 d6                     	movq	%rdx, %rsi
   3944d: 48 89 c7                     	movq	%rax, %rdi
   39450: e8 1b 86 fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   39455: 48 8d 05 b6 7a 06 00         	leaq	0x67ab6(%rip), %rax     # 0xa0f12 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0xb2>
   3945c: 48 89 c7                     	movq	%rax, %rdi
   3945f: e8 fc 81 fd ff               	callq	0x11660 <.plt.sec+0x870>
   39464: b8 00 00 00 00               	movl	$0x0, %eax
   39469: eb 57                        	jmp	0x394c2 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x23f>
   3946b: 8b 45 9c                     	movl	-0x64(%rbp), %eax
   3946e: 89 c7                        	movl	%eax, %edi
   39470: e8 7b 81 fd ff               	callq	0x115f0 <.plt.sec+0x800>
   39475: c1 e8 1f                     	shrl	$0x1f, %eax
   39478: 84 c0                        	testb	%al, %al
   3947a: 74 41                        	je	0x394bd <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x23a>
   3947c: 48 8d 05 95 7a 06 00         	leaq	0x67a95(%rip), %rax     # 0xa0f18 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0xb8>
   39483: 48 89 c6                     	movq	%rax, %rsi
   39486: 48 8d 05 b3 ab 0a 00         	leaq	0xaabb3(%rip), %rax     # 0xe4040 <_ZSt4cout@GLIBCXX_3.4>
   3948d: 48 89 c7                     	movq	%rax, %rdi
   39490: e8 1b 83 fd ff               	callq	0x117b0 <.plt.sec+0x9c0>
   39495: 48 8b 15 14 ab 0a 00         	movq	0xaab14(%rip), %rdx     # 0xe3fb0 <_GLOBAL_OFFSET_TABLE_+0x6e8>
   3949c: 48 89 d6                     	movq	%rdx, %rsi
   3949f: 48 89 c7                     	movq	%rax, %rdi
   394a2: e8 c9 85 fd ff               	callq	0x11a70 <.plt.sec+0xc80>
   394a7: 48 8d 05 7b 7a 06 00         	leaq	0x67a7b(%rip), %rax     # 0xa0f29 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0xc9>
   394ae: 48 89 c7                     	movq	%rax, %rdi
   394b1: e8 aa 81 fd ff               	callq	0x11660 <.plt.sec+0x870>
   394b6: b8 00 00 00 00               	movl	$0x0, %eax
   394bb: eb 05                        	jmp	0x394c2 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x23f>
   394bd: b8 00 00 00 00               	movl	$0x0, %eax
   394c2: 48 8b 55 f8                  	movq	-0x8(%rbp), %rdx
   394c6: 64 48 2b 14 25 28 00 00 00   	subq	%fs:0x28, %rdx
   394cf: 74 05                        	je	0x394d6 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)+0x253>
   394d1: e8 fa 7a fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   394d6: c9                           	leave
   394d7: c3                           	retq

00000000000394d8 <positionCanSender::sendPosition()>:
   394d8: f3 0f 1e fa                  	endbr64
   394dc: 55                           	pushq	%rbp
   394dd: 48 89 e5                     	movq	%rsp, %rbp
   394e0: 53                           	pushq	%rbx
   394e1: 48 83 ec 48                  	subq	$0x48, %rsp
   394e5: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   394ee: 48 89 45 e8                  	movq	%rax, -0x18(%rbp)
   394f2: 31 c0                        	xorl	%eax, %eax
   394f4: 48 89 e0                     	movq	%rsp, %rax
   394f7: 48 89 c3                     	movq	%rax, %rbx
   394fa: 8b 05 28 ab 0a 00            	movl	0xaab28(%rip), %eax     # 0xe4028 <directControl::JointCount>
   39500: 48 63 d0                     	movslq	%eax, %rdx
   39503: 48 83 ea 01                  	subq	$0x1, %rdx
   39507: 48 89 55 b8                  	movq	%rdx, -0x48(%rbp)
   3950b: 48 63 d0                     	movslq	%eax, %rdx
   3950e: 49 89 d0                     	movq	%rdx, %r8
   39511: 41 b9 00 00 00 00            	movl	$0x0, %r9d
   39517: 48 63 d0                     	movslq	%eax, %rdx
   3951a: 48 89 d6                     	movq	%rdx, %rsi
   3951d: bf 00 00 00 00               	movl	$0x0, %edi
   39522: 48 98                        	cltq
   39524: 48 8d 14 c5 00 00 00 00      	leaq	(,%rax,8), %rdx
   3952c: b8 10 00 00 00               	movl	$0x10, %eax
   39531: 48 83 e8 01                  	subq	$0x1, %rax
   39535: 48 01 d0                     	addq	%rdx, %rax
   39538: bf 10 00 00 00               	movl	$0x10, %edi
   3953d: ba 00 00 00 00               	movl	$0x0, %edx
   39542: 48 f7 f7                     	divq	%rdi
   39545: 48 6b c0 10                  	imulq	$0x10, %rax, %rax
   39549: 48 89 c1                     	movq	%rax, %rcx
   3954c: 48 81 e1 00 f0 ff ff         	andq	$-0x1000, %rcx          # imm = 0xF000
   39553: 48 89 e2                     	movq	%rsp, %rdx
   39556: 48 29 ca                     	subq	%rcx, %rdx
   39559: 48 39 d4                     	cmpq	%rdx, %rsp
   3955c: 74 12                        	je	0x39570 <positionCanSender::sendPosition()+0x98>
   3955e: 48 81 ec 00 10 00 00         	subq	$0x1000, %rsp           # imm = 0x1000
   39565: 48 83 8c 24 f8 0f 00 00 00   	orq	$0x0, 0xff8(%rsp)
   3956e: eb e9                        	jmp	0x39559 <positionCanSender::sendPosition()+0x81>
   39570: 48 89 c2                     	movq	%rax, %rdx
   39573: 81 e2 ff 0f 00 00            	andl	$0xfff, %edx            # imm = 0xFFF
   39579: 48 29 d4                     	subq	%rdx, %rsp
   3957c: 48 89 c2                     	movq	%rax, %rdx
   3957f: 81 e2 ff 0f 00 00            	andl	$0xfff, %edx            # imm = 0xFFF
   39585: 48 85 d2                     	testq	%rdx, %rdx
   39588: 74 10                        	je	0x3959a <positionCanSender::sendPosition()+0xc2>
   3958a: 25 ff 0f 00 00               	andl	$0xfff, %eax            # imm = 0xFFF
   3958f: 48 83 e8 08                  	subq	$0x8, %rax
   39593: 48 01 e0                     	addq	%rsp, %rax
   39596: 48 83 08 00                  	orq	$0x0, (%rax)
   3959a: 48 89 e0                     	movq	%rsp, %rax
   3959d: 48 83 c0 07                  	addq	$0x7, %rax
   395a1: 48 c1 e8 03                  	shrq	$0x3, %rax
   395a5: 48 c1 e0 03                  	shlq	$0x3, %rax
   395a9: 48 89 45 c0                  	movq	%rax, -0x40(%rbp)
   395ad: c7 45 b0 00 00 00 00         	movl	$0x0, -0x50(%rbp)
   395b4: e9 bd 00 00 00               	jmp	0x39676 <positionCanSender::sendPosition()+0x19e>
   395b9: 8b 45 b0                     	movl	-0x50(%rbp), %eax
   395bc: 48 98                        	cltq
   395be: 48 8d 14 85 00 00 00 00      	leaq	(,%rax,4), %rdx
   395c6: 48 8d 05 d3 ac 0a 00         	leaq	0xaacd3(%rip), %rax     # 0xe42a0 <robotConfig::RotationDirection>
   395cd: 8b 04 02                     	movl	(%rdx,%rax), %eax
   395d0: 66 0f ef c9                  	pxor	%xmm1, %xmm1
   395d4: f2 0f 2a c8                  	cvtsi2sd	%eax, %xmm1
   395d8: 8b 45 b0                     	movl	-0x50(%rbp), %eax
   395db: 48 98                        	cltq
   395dd: 48 8d 14 c5 00 00 00 00      	leaq	(,%rax,8), %rdx
   395e5: 48 8d 05 54 b9 0a 00         	leaq	0xab954(%rip), %rax     # 0xe4f40 <directControl::jointPositionTarget>
   395ec: f2 0f 10 04 02               	movsd	(%rdx,%rax), %xmm0
   395f1: f2 0f 59 c1                  	mulsd	%xmm1, %xmm0
   395f5: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   395f9: 8b 55 b0                     	movl	-0x50(%rbp), %edx
   395fc: 48 63 d2                     	movslq	%edx, %rdx
   395ff: f2 0f 11 04 d0               	movsd	%xmm0, (%rax,%rdx,8)
   39604: 48 8b 45 c0                  	movq	-0x40(%rbp), %rax
   39608: 8b 55 b0                     	movl	-0x50(%rbp), %edx
   3960b: 48 63 d2                     	movslq	%edx, %rdx
   3960e: f2 0f 10 0c d0               	movsd	(%rax,%rdx,8), %xmm1
   39613: f2 0f 10 05 15 79 06 00      	movsd	0x67915(%rip), %xmm0    # 0xa0f30 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0xd0>
   3961b: f2 0f 59 c1                  	mulsd	%xmm1, %xmm0
   3961f: f2 0f 2c c0                  	cvttsd2si	%xmm0, %eax
   39623: 89 45 b4                     	movl	%eax, -0x4c(%rbp)
   39626: 83 7d b4 00                  	cmpl	$0x0, -0x4c(%rbp)
   3962a: 79 07                        	jns	0x39633 <positionCanSender::sendPosition()+0x15b>
   3962c: 81 45 b4 ff ff 00 00         	addl	$0xffff, -0x4c(%rbp)    # imm = 0xFFFF
   39633: c7 45 cc 00 00 00 00         	movl	$0x0, -0x34(%rbp)
   3963a: 8b 45 b4                     	movl	-0x4c(%rbp), %eax
   3963d: 89 45 cc                     	movl	%eax, -0x34(%rbp)
   39640: 0f b6 45 cd                  	movzbl	-0x33(%rbp), %eax
   39644: 88 45 d6                     	movb	%al, -0x2a(%rbp)
   39647: 0f b6 45 cc                  	movzbl	-0x34(%rbp), %eax
   3964b: 88 45 d7                     	movb	%al, -0x29(%rbp)
   3964e: c6 45 d5 40                  	movb	$0x40, -0x2b(%rbp)
   39652: 8b 45 b0                     	movl	-0x50(%rbp), %eax
   39655: 83 c0 11                     	addl	$0x11, %eax
   39658: 89 45 d0                     	movl	%eax, -0x30(%rbp)
   3965b: c6 45 d4 03                  	movb	$0x3, -0x2c(%rbp)
   3965f: 48 8b 55 d0                  	movq	-0x30(%rbp), %rdx
   39663: 48 8b 45 d8                  	movq	-0x28(%rbp), %rax
   39667: 48 89 d7                     	movq	%rdx, %rdi
   3966a: 48 89 c6                     	movq	%rax, %rsi
   3966d: e8 11 fc ff ff               	callq	0x39283 <positionCanSender::CAN_Send(positionCanSender::CanFrame_t)>
   39672: 83 45 b0 01                  	addl	$0x1, -0x50(%rbp)
   39676: 8b 05 ac a9 0a 00            	movl	0xaa9ac(%rip), %eax     # 0xe4028 <directControl::JointCount>
   3967c: 39 45 b0                     	cmpl	%eax, -0x50(%rbp)
   3967f: 0f 8c 34 ff ff ff            	jl	0x395b9 <positionCanSender::sendPosition()+0xe1>
   39685: 90                           	nop
   39686: 48 89 dc                     	movq	%rbx, %rsp
   39689: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   3968d: 64 48 2b 04 25 28 00 00 00   	subq	%fs:0x28, %rax
   39696: 74 05                        	je	0x3969d <positionCanSender::sendPosition()+0x1c5>
   39698: e8 33 79 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   3969d: 48 8b 5d f8                  	movq	-0x8(%rbp), %rbx
   396a1: c9                           	leave
   396a2: c3                           	retq

00000000000396a3 <positionCanSender::spin()>:
   396a3: f3 0f 1e fa                  	endbr64
   396a7: 55                           	pushq	%rbp
   396a8: 48 89 e5                     	movq	%rsp, %rbp
   396ab: 48 83 ec 10                  	subq	$0x10, %rsp
   396af: 48 8b 05 f2 bb 0a 00         	movq	0xabbf2(%rip), %rax     # 0xe52a8 <RealTimer::globalIter>
   396b6: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   396ba: 48 8b 05 e7 bb 0a 00         	movq	0xabbe7(%rip), %rax     # 0xe52a8 <RealTimer::globalIter>
   396c1: 48 39 45 f8                  	cmpq	%rax, -0x8(%rbp)
   396c5: 72 07                        	jb	0x396ce <positionCanSender::spin()+0x2b>
   396c7: e8 8e 00 00 00               	callq	0x3975a <std::this_thread::yield()>
   396cc: eb ec                        	jmp	0x396ba <positionCanSender::spin()+0x17>
   396ce: e8 05 fe ff ff               	callq	0x394d8 <positionCanSender::sendPosition()>
   396d3: 48 8b 05 ce bb 0a 00         	movq	0xabbce(%rip), %rax     # 0xe52a8 <RealTimer::globalIter>
   396da: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   396de: eb da                        	jmp	0x396ba <positionCanSender::spin()+0x17>
