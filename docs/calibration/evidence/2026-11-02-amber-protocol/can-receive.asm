
Amber-HomeFolder/amber/L-10/amber_core_L:	file format elf64-x86-64

Disassembly of section .text:

0000000000038d99 <canRecv::convertfromCan(canRecv::CanFrame_t)>:
   38d99: f3 0f 1e fa                  	endbr64
   38d9d: 55                           	pushq	%rbp
   38d9e: 48 89 e5                     	movq	%rsp, %rbp
   38da1: 48 83 ec 50                  	subq	$0x50, %rsp
   38da5: 48 89 f8                     	movq	%rdi, %rax
   38da8: 48 89 f1                     	movq	%rsi, %rcx
   38dab: 48 89 ca                     	movq	%rcx, %rdx
   38dae: 48 89 45 b0                  	movq	%rax, -0x50(%rbp)
   38db2: 48 89 55 b8                  	movq	%rdx, -0x48(%rbp)
   38db6: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   38dbf: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   38dc3: 31 c0                        	xorl	%eax, %eax
   38dc5: 8b 45 b0                     	movl	-0x50(%rbp), %eax
   38dc8: 89 45 d8                     	movl	%eax, -0x28(%rbp)
   38dcb: 81 6d d8 90 00 00 00         	subl	$0x90, -0x28(%rbp)
   38dd2: c7 45 cc 00 00 00 00         	movl	$0x0, -0x34(%rbp)
   38dd9: c7 45 d0 00 00 00 00         	movl	$0x0, -0x30(%rbp)
   38de0: c7 45 d4 00 00 00 00         	movl	$0x0, -0x2c(%rbp)
   38de7: 0f b6 45 b6                  	movzbl	-0x4a(%rbp), %eax
   38deb: 88 45 ed                     	movb	%al, -0x13(%rbp)
   38dee: 0f b6 45 b7                  	movzbl	-0x49(%rbp), %eax
   38df2: 88 45 ec                     	movb	%al, -0x14(%rbp)
   38df5: c6 45 ee 00                  	movb	$0x0, -0x12(%rbp)
   38df9: c6 45 ef 00                  	movb	$0x0, -0x11(%rbp)
   38dfd: 0f b7 45 ec                  	movzwl	-0x14(%rbp), %eax
   38e01: 66 3d 00 80                  	cmpw	$0x8000, %ax            # imm = 0x8000
   38e05: 76 11                        	jbe	0x38e18 <canRecv::convertfromCan(canRecv::CanFrame_t)+0x7f>
   38e07: 0f b7 45 ec                  	movzwl	-0x14(%rbp), %eax
   38e0b: 0f b7 c0                     	movzwl	%ax, %eax
   38e0e: 2d ff ff 00 00               	subl	$0xffff, %eax           # imm = 0xFFFF
   38e13: 89 45 cc                     	movl	%eax, -0x34(%rbp)
   38e16: eb 0a                        	jmp	0x38e22 <canRecv::convertfromCan(canRecv::CanFrame_t)+0x89>
   38e18: 0f b7 45 ec                  	movzwl	-0x14(%rbp), %eax
   38e1c: 0f b7 c0                     	movzwl	%ax, %eax
   38e1f: 89 45 cc                     	movl	%eax, -0x34(%rbp)
   38e22: 0f b6 45 b8                  	movzbl	-0x48(%rbp), %eax
   38e26: 88 45 f1                     	movb	%al, -0xf(%rbp)
   38e29: 0f b6 45 b9                  	movzbl	-0x47(%rbp), %eax
   38e2d: 88 45 f0                     	movb	%al, -0x10(%rbp)
   38e30: c6 45 f2 00                  	movb	$0x0, -0xe(%rbp)
   38e34: c6 45 f3 00                  	movb	$0x0, -0xd(%rbp)
   38e38: 0f b7 45 f0                  	movzwl	-0x10(%rbp), %eax
   38e3c: 66 3d 00 80                  	cmpw	$0x8000, %ax            # imm = 0x8000
   38e40: 76 11                        	jbe	0x38e53 <canRecv::convertfromCan(canRecv::CanFrame_t)+0xba>
   38e42: 0f b7 45 f0                  	movzwl	-0x10(%rbp), %eax
   38e46: 0f b7 c0                     	movzwl	%ax, %eax
   38e49: 2d ff ff 00 00               	subl	$0xffff, %eax           # imm = 0xFFFF
   38e4e: 89 45 d0                     	movl	%eax, -0x30(%rbp)
   38e51: eb 0a                        	jmp	0x38e5d <canRecv::convertfromCan(canRecv::CanFrame_t)+0xc4>
   38e53: 0f b7 45 f0                  	movzwl	-0x10(%rbp), %eax
   38e57: 0f b7 c0                     	movzwl	%ax, %eax
   38e5a: 89 45 d0                     	movl	%eax, -0x30(%rbp)
   38e5d: 0f b6 45 ba                  	movzbl	-0x46(%rbp), %eax
   38e61: 88 45 f5                     	movb	%al, -0xb(%rbp)
   38e64: 0f b6 45 bb                  	movzbl	-0x45(%rbp), %eax
   38e68: 88 45 f4                     	movb	%al, -0xc(%rbp)
   38e6b: c6 45 f6 00                  	movb	$0x0, -0xa(%rbp)
   38e6f: c6 45 f7 00                  	movb	$0x0, -0x9(%rbp)
   38e73: 0f b7 45 f4                  	movzwl	-0xc(%rbp), %eax
   38e77: 66 3d 00 80                  	cmpw	$0x8000, %ax            # imm = 0x8000
   38e7b: 76 11                        	jbe	0x38e8e <canRecv::convertfromCan(canRecv::CanFrame_t)+0xf5>
   38e7d: 0f b7 45 f4                  	movzwl	-0xc(%rbp), %eax
   38e81: 0f b7 c0                     	movzwl	%ax, %eax
   38e84: 2d ff ff 00 00               	subl	$0xffff, %eax           # imm = 0xFFFF
   38e89: 89 45 d4                     	movl	%eax, -0x2c(%rbp)
   38e8c: eb 0a                        	jmp	0x38e98 <canRecv::convertfromCan(canRecv::CanFrame_t)+0xff>
   38e8e: 0f b7 45 f4                  	movzwl	-0xc(%rbp), %eax
   38e92: 0f b7 c0                     	movzwl	%ax, %eax
   38e95: 89 45 d4                     	movl	%eax, -0x2c(%rbp)
   38e98: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38e9c: f3 0f 2a 45 cc               	cvtsi2ssl	-0x34(%rbp), %xmm0
   38ea1: f3 0f 11 45 dc               	movss	%xmm0, -0x24(%rbp)
   38ea6: f3 0f 10 45 dc               	movss	-0x24(%rbp), %xmm0
   38eab: f3 0f 10 0d 11 80 06 00      	movss	0x68011(%rip), %xmm1    # 0xa0ec4 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x64>
   38eb3: f3 0f 5e c1                  	divss	%xmm1, %xmm0
   38eb7: f3 0f 11 45 dc               	movss	%xmm0, -0x24(%rbp)
   38ebc: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38ec0: f3 0f 2a 45 d0               	cvtsi2ssl	-0x30(%rbp), %xmm0
   38ec5: f3 0f 11 45 e0               	movss	%xmm0, -0x20(%rbp)
   38eca: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38ece: f3 0f 2a 45 d4               	cvtsi2ssl	-0x2c(%rbp), %xmm0
   38ed3: f3 0f 11 45 e4               	movss	%xmm0, -0x1c(%rbp)
   38ed8: f3 0f 10 45 e4               	movss	-0x1c(%rbp), %xmm0
   38edd: f3 0f 10 0d e3 7f 06 00      	movss	0x67fe3(%rip), %xmm1    # 0xa0ec8 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x68>
   38ee5: f3 0f 5e c1                  	divss	%xmm1, %xmm0
   38ee9: f3 0f 11 45 e4               	movss	%xmm0, -0x1c(%rbp)
   38eee: 0f b6 45 bc                  	movzbl	-0x44(%rbp), %eax
   38ef2: 0f b6 c0                     	movzbl	%al, %eax
   38ef5: 89 45 e8                     	movl	%eax, -0x18(%rbp)
   38ef8: 8b 45 d8                     	movl	-0x28(%rbp), %eax
   38efb: 83 e8 01                     	subl	$0x1, %eax
   38efe: 48 98                        	cltq
   38f00: 48 8d 14 85 00 00 00 00      	leaq	(,%rax,4), %rdx
   38f08: 48 8d 05 91 b3 0a 00         	leaq	0xab391(%rip), %rax     # 0xe42a0 <robotConfig::RotationDirection>
   38f0f: 8b 04 02                     	movl	(%rdx,%rax), %eax
   38f12: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38f16: f3 0f 2a c0                  	cvtsi2ss	%eax, %xmm0
   38f1a: f3 0f 59 45 dc               	mulss	-0x24(%rbp), %xmm0
   38f1f: 8b 45 d8                     	movl	-0x28(%rbp), %eax
   38f22: 83 e8 01                     	subl	$0x1, %eax
   38f25: f3 0f 5a c0                  	cvtss2sd	%xmm0, %xmm0
   38f29: 48 98                        	cltq
   38f2b: 48 8d 14 c5 00 00 00 00      	leaq	(,%rax,8), %rdx
   38f33: 48 8d 05 86 bc 0a 00         	leaq	0xabc86(%rip), %rax     # 0xe4bc0 <directControl::jointPositionNow>
   38f3a: f2 0f 11 04 02               	movsd	%xmm0, (%rdx,%rax)
   38f3f: 8b 45 d8                     	movl	-0x28(%rbp), %eax
   38f42: 83 e8 01                     	subl	$0x1, %eax
   38f45: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38f49: f3 0f 5a 45 e0               	cvtss2sd	-0x20(%rbp), %xmm0
   38f4e: 48 98                        	cltq
   38f50: 48 8d 14 c5 00 00 00 00      	leaq	(,%rax,8), %rdx
   38f58: 48 8d 05 61 bd 0a 00         	leaq	0xabd61(%rip), %rax     # 0xe4cc0 <directControl::jointVelocityNow>
   38f5f: f2 0f 11 04 02               	movsd	%xmm0, (%rdx,%rax)
   38f64: 8b 45 d8                     	movl	-0x28(%rbp), %eax
   38f67: 83 e8 01                     	subl	$0x1, %eax
   38f6a: 66 0f ef c0                  	pxor	%xmm0, %xmm0
   38f6e: f3 0f 5a 45 e4               	cvtss2sd	-0x1c(%rbp), %xmm0
   38f73: 48 98                        	cltq
   38f75: 48 8d 14 c5 00 00 00 00      	leaq	(,%rax,8), %rdx
   38f7d: 48 8d 05 3c be 0a 00         	leaq	0xabe3c(%rip), %rax     # 0xe4dc0 <directControl::jointCurrentNow>
   38f84: f2 0f 11 04 02               	movsd	%xmm0, (%rdx,%rax)
   38f89: 8b 45 d8                     	movl	-0x28(%rbp), %eax
   38f8c: 83 e8 01                     	subl	$0x1, %eax
   38f8f: 48 98                        	cltq
   38f91: 48 8d 0c 85 00 00 00 00      	leaq	(,%rax,4), %rcx
   38f99: 48 8d 15 20 bf 0a 00         	leaq	0xabf20(%rip), %rdx     # 0xe4ec0 <directControl::jointStatusNow>
   38fa0: 8b 45 e8                     	movl	-0x18(%rbp), %eax
   38fa3: 89 04 11                     	movl	%eax, (%rcx,%rdx)
   38fa6: 90                           	nop
   38fa7: 48 8b 45 f8                  	movq	-0x8(%rbp), %rax
   38fab: 64 48 2b 04 25 28 00 00 00   	subq	%fs:0x28, %rax
   38fb4: 74 05                        	je	0x38fbb <canRecv::convertfromCan(canRecv::CanFrame_t)+0x222>
   38fb6: e8 15 80 fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   38fbb: c9                           	leave
   38fbc: c3                           	retq

0000000000038fbd <canRecv::CAN_Recv()>:
   38fbd: f3 0f 1e fa                  	endbr64
   38fc1: 55                           	pushq	%rbp
   38fc2: 48 89 e5                     	movq	%rsp, %rbp
   38fc5: 48 83 ec 20                  	subq	$0x20, %rsp
   38fc9: 64 48 8b 04 25 28 00 00 00   	movq	%fs:0x28, %rax
   38fd2: 48 89 45 f8                  	movq	%rax, -0x8(%rbp)
   38fd6: 31 c0                        	xorl	%eax, %eax
   38fd8: ba 01 00 00 00               	movl	$0x1, %edx
   38fdd: be 03 00 00 00               	movl	$0x3, %esi
   38fe2: bf 1d 00 00 00               	movl	$0x1d, %edi
   38fe7: e8 34 87 fd ff               	callq	0x11720 <.plt.sec+0x930>
   38fec: 89 05 12 b6 0a 00            	movl	%eax, 0xab612(%rip)     # 0xe4604 <canRecv::s>
   38ff2: 8b 05 0c b6 0a 00            	movl	0xab60c(%rip), %eax     # 0xe4604 <canRecv::s>
   38ff8: c1 e8 1f                     	shrl	$0x1f, %eax
   38ffb: 84 c0                        	testb	%al, %al
   38ffd: 74 19                        	je	0x39018 <canRecv::CAN_Recv()+0x5b>
   38fff: 48 8d 05 a2 7e 06 00         	leaq	0x67ea2(%rip), %rax     # 0xa0ea8 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x48>
   39006: 48 89 c7                     	movq	%rax, %rdi
   39009: e8 52 86 fd ff               	callq	0x11660 <.plt.sec+0x870>
   3900e: b8 01 00 00 00               	movl	$0x1, %eax
   39013: e9 d7 01 00 00               	jmp	0x391ef <canRecv::CAN_Recv()+0x232>
   39018: 48 8d 05 c1 b4 0a 00         	leaq	0xab4c1(%rip), %rax     # 0xe44e0 <canBus::DeviceName[abi:cxx11]>
   3901f: 48 89 c7                     	movq	%rax, %rdi
   39022: e8 09 85 fd ff               	callq	0x11530 <.plt.sec+0x740>
   39027: 48 89 c6                     	movq	%rax, %rsi
   3902a: 48 8d 05 0f b6 0a 00         	leaq	0xab60f(%rip), %rax     # 0xe4640 <canRecv::ifr>
   39031: 48 89 c7                     	movq	%rax, %rdi
   39034: e8 a7 86 fd ff               	callq	0x116e0 <.plt.sec+0x8f0>
   39039: 8b 05 c5 b5 0a 00            	movl	0xab5c5(%rip), %eax     # 0xe4604 <canRecv::s>
   3903f: 48 8d 15 fa b5 0a 00         	leaq	0xab5fa(%rip), %rdx     # 0xe4640 <canRecv::ifr>
   39046: be 33 89 00 00               	movl	$0x8933, %esi           # imm = 0x8933
   3904b: 89 c7                        	movl	%eax, %edi
   3904d: b8 00 00 00 00               	movl	$0x0, %eax
   39052: e8 59 7e fd ff               	callq	0x10eb0 <.plt.sec+0xc0>
   39057: ba 18 00 00 00               	movl	$0x18, %edx
   3905c: be 00 00 00 00               	movl	$0x0, %esi
   39061: 48 8d 05 a8 b5 0a 00         	leaq	0xab5a8(%rip), %rax     # 0xe4610 <canRecv::addr>
   39068: 48 89 c7                     	movq	%rax, %rdi
   3906b: e8 70 7f fd ff               	callq	0x10fe0 <.plt.sec+0x1f0>
   39070: 66 c7 05 97 b5 0a 00 1d 00   	movw	$0x1d, 0xab597(%rip)    # 0xe4610 <canRecv::addr>
   39079: 8b 05 d1 b5 0a 00            	movl	0xab5d1(%rip), %eax     # 0xe4650 <canRecv::ifr+0x10>
   3907f: 89 05 8f b5 0a 00            	movl	%eax, 0xab58f(%rip)     # 0xe4614 <canRecv::addr+0x4>
   39085: 8b 05 79 b5 0a 00            	movl	0xab579(%rip), %eax     # 0xe4604 <canRecv::s>
   3908b: ba 18 00 00 00               	movl	$0x18, %edx
   39090: 48 8d 0d 79 b5 0a 00         	leaq	0xab579(%rip), %rcx     # 0xe4610 <canRecv::addr>
   39097: 48 89 ce                     	movq	%rcx, %rsi
   3909a: 89 c7                        	movl	%eax, %edi
   3909c: e8 ff 88 fd ff               	callq	0x119a0 <.plt.sec+0xbb0>
   390a1: c1 e8 1f                     	shrl	$0x1f, %eax
   390a4: 84 c0                        	testb	%al, %al
   390a6: 74 19                        	je	0x390c1 <canRecv::CAN_Recv()+0x104>
   390a8: 48 8d 05 02 7e 06 00         	leaq	0x67e02(%rip), %rax     # 0xa0eb1 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x51>
   390af: 48 89 c7                     	movq	%rax, %rdi
   390b2: e8 a9 85 fd ff               	callq	0x11660 <.plt.sec+0x870>
   390b7: b8 01 00 00 00               	movl	$0x1, %eax
   390bc: e9 2e 01 00 00               	jmp	0x391ef <canRecv::CAN_Recv()+0x232>
   390c1: c7 05 b5 b5 0a 00 90 00 00 00	movl	$0x90, 0xab5b5(%rip)    # 0xe4680 <canRecv::rfilter>
   390cb: c7 05 af b5 0a 00 f0 07 00 00	movl	$0x7f0, 0xab5af(%rip)   # imm = 0x7F0
                                                                        # 0xe4684 <canRecv::rfilter+0x4>
   390d5: 8b 05 29 b5 0a 00            	movl	0xab529(%rip), %eax     # 0xe4604 <canRecv::s>
   390db: 41 b8 08 00 00 00            	movl	$0x8, %r8d
   390e1: 48 8d 15 98 b5 0a 00         	leaq	0xab598(%rip), %rdx     # 0xe4680 <canRecv::rfilter>
   390e8: 48 89 d1                     	movq	%rdx, %rcx
   390eb: ba 01 00 00 00               	movl	$0x1, %edx
   390f0: be 65 00 00 00               	movl	$0x65, %esi
   390f5: 89 c7                        	movl	%eax, %edi
   390f7: e8 74 84 fd ff               	callq	0x11570 <.plt.sec+0x780>
   390fc: c7 05 fa b4 0a 00 01 00 00 00	movl	$0x1, 0xab4fa(%rip)     # 0xe4600 <canRecv::recverInited>
   39106: 8b 05 f8 b4 0a 00            	movl	0xab4f8(%rip), %eax     # 0xe4604 <canRecv::s>
   3910c: ba 10 00 00 00               	movl	$0x10, %edx
   39111: 48 8d 0d 58 b5 0a 00         	leaq	0xab558(%rip), %rcx     # 0xe4670 <canRecv::frame>
   39118: 48 89 ce                     	movq	%rcx, %rsi
   3911b: 89 c7                        	movl	%eax, %edi
   3911d: e8 6e 87 fd ff               	callq	0x11890 <.plt.sec+0xaa0>
   39122: 89 05 e4 b4 0a 00            	movl	%eax, 0xab4e4(%rip)     # 0xe460c <canRecv::nbytes>
   39128: 8b 05 de b4 0a 00            	movl	0xab4de(%rip), %eax     # 0xe460c <canRecv::nbytes>
   3912e: 85 c0                        	testl	%eax, %eax
   39130: 79 19                        	jns	0x3914b <canRecv::CAN_Recv()+0x18e>
   39132: 48 8d 05 7d 7d 06 00         	leaq	0x67d7d(%rip), %rax     # 0xa0eb6 <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x56>
   39139: 48 89 c7                     	movq	%rax, %rdi
   3913c: e8 1f 85 fd ff               	callq	0x11660 <.plt.sec+0x870>
   39141: b8 01 00 00 00               	movl	$0x1, %eax
   39146: e9 a4 00 00 00               	jmp	0x391ef <canRecv::CAN_Recv()+0x232>
   3914b: 8b 05 1f b5 0a 00            	movl	0xab51f(%rip), %eax     # 0xe4670 <canRecv::frame>
   39151: 89 45 e0                     	movl	%eax, -0x20(%rbp)
   39154: 0f b6 05 19 b5 0a 00         	movzbl	0xab519(%rip), %eax     # 0xe4674 <canRecv::frame+0x4>
   3915b: 88 45 e4                     	movb	%al, -0x1c(%rbp)
   3915e: c7 05 a0 b4 0a 00 00 00 00 00	movl	$0x0, 0xab4a0(%rip)     # 0xe4608 <canRecv::i>
   39168: eb 2f                        	jmp	0x39199 <canRecv::CAN_Recv()+0x1dc>
   3916a: 8b 05 98 b4 0a 00            	movl	0xab498(%rip), %eax     # 0xe4608 <canRecv::i>
   39170: 8b 0d 92 b4 0a 00            	movl	0xab492(%rip), %ecx     # 0xe4608 <canRecv::i>
   39176: 48 98                        	cltq
   39178: 48 8d 15 f9 b4 0a 00         	leaq	0xab4f9(%rip), %rdx     # 0xe4678 <canRecv::frame+0x8>
   3917f: 0f b6 14 10                  	movzbl	(%rax,%rdx), %edx
   39183: 48 63 c1                     	movslq	%ecx, %rax
   39186: 88 54 05 e5                  	movb	%dl, -0x1b(%rbp,%rax)
   3918a: 8b 05 78 b4 0a 00            	movl	0xab478(%rip), %eax     # 0xe4608 <canRecv::i>
   39190: 83 c0 01                     	addl	$0x1, %eax
   39193: 89 05 6f b4 0a 00            	movl	%eax, 0xab46f(%rip)     # 0xe4608 <canRecv::i>
   39199: 0f b6 05 d4 b4 0a 00         	movzbl	0xab4d4(%rip), %eax     # 0xe4674 <canRecv::frame+0x4>
   391a0: 0f b6 d0                     	movzbl	%al, %edx
   391a3: 8b 05 5f b4 0a 00            	movl	0xab45f(%rip), %eax     # 0xe4608 <canRecv::i>
   391a9: 39 c2                        	cmpl	%eax, %edx
   391ab: 7f bd                        	jg	0x3916a <canRecv::CAN_Recv()+0x1ad>
   391ad: 8b 05 51 b4 0a 00            	movl	0xab451(%rip), %eax     # 0xe4604 <canRecv::s>
   391b3: 89 c7                        	movl	%eax, %edi
   391b5: e8 36 84 fd ff               	callq	0x115f0 <.plt.sec+0x800>
   391ba: c1 e8 1f                     	shrl	$0x1f, %eax
   391bd: 84 c0                        	testb	%al, %al
   391bf: 74 16                        	je	0x391d7 <canRecv::CAN_Recv()+0x21a>
   391c1: 48 8d 05 f3 7c 06 00         	leaq	0x67cf3(%rip), %rax     # 0xa0ebb <typeinfo name for nlohmann::json_abi_v3_11_2::detail::exception+0x5b>
   391c8: 48 89 c7                     	movq	%rax, %rdi
   391cb: e8 90 84 fd ff               	callq	0x11660 <.plt.sec+0x870>
   391d0: b8 01 00 00 00               	movl	$0x1, %eax
   391d5: eb 18                        	jmp	0x391ef <canRecv::CAN_Recv()+0x232>
   391d7: 48 8b 55 e0                  	movq	-0x20(%rbp), %rdx
   391db: 48 8b 45 e8                  	movq	-0x18(%rbp), %rax
   391df: 48 89 d7                     	movq	%rdx, %rdi
   391e2: 48 89 c6                     	movq	%rax, %rsi
   391e5: e8 af fb ff ff               	callq	0x38d99 <canRecv::convertfromCan(canRecv::CanFrame_t)>
   391ea: e9 e9 fd ff ff               	jmp	0x38fd8 <canRecv::CAN_Recv()+0x1b>
   391ef: 48 8b 55 f8                  	movq	-0x8(%rbp), %rdx
   391f3: 64 48 2b 14 25 28 00 00 00   	subq	%fs:0x28, %rdx
   391fc: 74 05                        	je	0x39203 <canRecv::CAN_Recv()+0x246>
   391fe: e8 cd 7d fd ff               	callq	0x10fd0 <.plt.sec+0x1e0>
   39203: c9                           	leave
   39204: c3                           	retq

0000000000039205 <canRecv::spin()>:
   39205: f3 0f 1e fa                  	endbr64
   39209: 55                           	pushq	%rbp
   3920a: 48 89 e5                     	movq	%rsp, %rbp
   3920d: e8 ab fd ff ff               	callq	0x38fbd <canRecv::CAN_Recv()>
   39212: eb f9                        	jmp	0x3920d <canRecv::spin()+0x8>
