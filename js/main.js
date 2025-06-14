document.addEventListener('DOMContentLoaded', function() {
    // 初始化标签页
    initTabs();
    
    // 初始化手风琴组件
    initAccordion();
    
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

// 初始化标签页功能
function initTabs() {
    const tabHeaders = document.querySelectorAll('.tab-header');
    if (tabHeaders.length === 0) return;
    
    // 设置第一个标签为活动状态
    const firstTabHeader = tabHeaders[0];
    const tabContents = document.querySelectorAll('.tab-content');
    const firstTabContent = tabContents[0];
    
    if (!firstTabHeader.classList.contains('active')) {
        firstTabHeader.classList.add('active');
    }
    
    if (!firstTabContent.classList.contains('active')) {
        firstTabContent.classList.add('active');
    }
    
    // 为每个标签头添加点击事件
    tabHeaders.forEach((header, index) => {
        header.addEventListener('click', function() {
            // 移除所有活动标签
            tabHeaders.forEach(h => h.classList.remove('active'));
            tabContents.forEach(c => c.classList.remove('active'));
            
            // 激活当前标签
            this.classList.add('active');
            tabContents[index].classList.add('active');
        });
    });
}

// 初始化手风琴组件功能
function initAccordion() {
    const accordionHeaders = document.querySelectorAll('.accordion-header');
    if (accordionHeaders.length === 0) return;
    
    // 默认打开第一个手风琴项
    if (!accordionHeaders[0].classList.contains('active')) {
        accordionHeaders[0].classList.add('active');
    }
    
    // 为每个手风琴头部添加点击事件
    accordionHeaders.forEach(header => {
        header.addEventListener('click', function() {
            this.classList.toggle('active');
        });
    });
}
