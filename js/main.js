document.addEventListener('DOMContentLoaded', function() {
    // 标签页切换功能
    const tabContainers = document.querySelectorAll('.tab-container');
    
    tabContainers.forEach(container => {
        const tabs = container.querySelectorAll('.tab');
        const tabPanes = container.querySelectorAll('.tab-pane');
        
        tabs.forEach((tab, index) => {
            tab.addEventListener('click', () => {
                // 移除所有活动标签和内容
                tabs.forEach(t => t.classList.remove('active'));
                tabPanes.forEach(p => p.classList.remove('active'));
                
                // 激活当前标签和内容
                tab.classList.add('active');
                tabPanes[index].classList.add('active');
            });
        });
        
        // 默认激活第一个标签
        if(tabs.length > 0 && tabPanes.length > 0) {
            tabs[0].classList.add('active');
            tabPanes[0].classList.add('active');
        }
    });
    
    // 手风琴功能
    const accordionHeaders = document.querySelectorAll('.accordion-header');
    
    accordionHeaders.forEach(header => {
        header.addEventListener('click', () => {
            const content = header.nextElementSibling;
            const isOpen = header.classList.contains('active');
            
            // 切换当前项
            if (!isOpen) {
                header.classList.add('active');
                content.style.maxHeight = content.scrollHeight + 'px';
            } else {
                header.classList.remove('active');
                content.style.maxHeight = null;
            }
        });
    });
    
    // 初始化手风琴状态 - 确保所有内容初始为关闭状态
    document.querySelectorAll('.accordion-content').forEach(content => {
        content.style.maxHeight = null;
    });
    
    // 交互式网络图表动画
    const networkDiagrams = document.querySelectorAll('.interactive-diagram');
    
    networkDiagrams.forEach(diagram => {
        const controls = diagram.querySelectorAll('.control-button');
        
        controls.forEach(control => {
            control.addEventListener('click', function() {
                const action = this.getAttribute('data-action');
                const target = this.getAttribute('data-target');
                const svgDoc = diagram.querySelector('object').contentDocument;
                
                if (svgDoc) {
                    const targetElement = svgDoc.getElementById(target);
                    
                    if (targetElement) {
                        switch(action) {
                            case 'highlight':
                                // 移除所有高亮
                                svgDoc.querySelectorAll('.highlight').forEach(el => {
                                    el.classList.remove('highlight');
                                });
                                targetElement.classList.add('highlight');
                                break;
                            case 'animate':
                                // 触发动画
                                targetElement.classList.remove('animate');
                                void targetElement.offsetWidth; // 触发重绘
                                targetElement.classList.add('animate');
                                break;
                            case 'toggle':
                                // 切换显示/隐藏
                                if (targetElement.style.opacity === '0') {
                                    targetElement.style.opacity = '1';
                                } else {
                                    targetElement.style.opacity = '0';
                                }
                                break;
                        }
                    }
                }
            });
        });
    });
    
    // 代码块复制功能
    const codeBlocks = document.querySelectorAll('.code-block');
    
    codeBlocks.forEach(block => {
        const copyButton = document.createElement('button');
        copyButton.className = 'copy-button';
        copyButton.textContent = '复制';
        copyButton.style.position = 'absolute';
        copyButton.style.right = '10px';
        copyButton.style.top = '10px';
        copyButton.style.padding = '5px 10px';
        copyButton.style.background = '#f0f0f0';
        copyButton.style.border = 'none';
        copyButton.style.borderRadius = '4px';
        copyButton.style.cursor = 'pointer';
        
        // 确保代码块有相对定位，以便复制按钮定位正确
        block.style.position = 'relative';
        
        block.appendChild(copyButton);
        
        copyButton.addEventListener('click', () => {
            const code = block.textContent.replace('复制', '').trim();
            navigator.clipboard.writeText(code).then(() => {
                copyButton.textContent = '已复制!';
                setTimeout(() => {
                    copyButton.textContent = '复制';
                }, 2000);
            });
        });
    });
    
    // 实验步骤交互
    const experimentSteps = document.querySelectorAll('.experiment-step');
    
    experimentSteps.forEach(step => {
        const checkButton = step.querySelector('.check-button');
        if (checkButton) {
            checkButton.addEventListener('click', function() {
                const result = step.querySelector('.step-result');
                result.style.display = 'block';
                this.disabled = true;
            });
        }
    });
});
